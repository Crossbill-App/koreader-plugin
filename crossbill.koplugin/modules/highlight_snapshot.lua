--[[
Highlight Snapshot Module for Crossbill Sync

Remembers, per book, the server highlights the device last applied: one row per
highlight, holding the server's id and the sha256 of its text. Without that
memory the plugin cannot tell a highlight deleted on the device from one that
never existed here, nor a fresh highlight from a stale echo of a removed one.

A book enrols on its first successful pull, and only highlights the importer
actually placed are recorded: an unplaceable one would later read as "deleted on
the device". `findRemoved` then diffs the book's current highlights against that
memory, which is how a deletion made on the device is recognised.

The snapshot mirrors server state, so it is keyed by client_book_id (the hash of
"title|author") rather than by the file path: it survives moves and is shared by
copies of the same book.

Storage arrives as a dependency. On the device that is
`modules/highlight_snapshot_store`, which talks to SQLite; specs hand it an
in-memory stand-in, so this module never pulls the reader's SQLite binding into
their require graph.
]]

local logger = require("logger")
local sha2 = require("ffi/sha2")

local HighlightSnapshot = {}
HighlightSnapshot.__index = HighlightSnapshot

--- Hash a highlight's text the way the server hashes it
-- The server's dedup identity (ContentHash) is sha256 over the text as stored,
-- with no normalisation, so the device hashes it verbatim. Text the server
-- could not have hashed -- empty, or a JSON null decoded to a sentinel -- has no
-- identity to record.
-- @param text any The highlight's text
-- @return string|nil The hex digest, or nil when there is no text to hash
function HighlightSnapshot.hashText(text)
	if type(text) ~= "string" or text == "" then
		return nil
	end
	return sha2.sha256(text)
end

--- Create a new HighlightSnapshot instance
-- @param deps table Collaborators:
--   store The snapshot store to keep the rows in
-- @return HighlightSnapshot instance
function HighlightSnapshot:new(deps)
	local instance = setmetatable({}, HighlightSnapshot)
	instance.store = deps and deps.store
	instance._initialized = false
	return instance
end

--- Open the ledger's storage
-- @param data_dir string Path to KOReader's settings directory
-- @return boolean Success status
function HighlightSnapshot:init(data_dir)
	if self._initialized then
		return true
	end

	if not self.store then
		logger.warn("Crossbill HighlightSnapshot: No store to open")
		return false
	end

	local ok, opened = pcall(function()
		return self.store:open(data_dir)
	end)

	if not ok then
		logger.err("Crossbill HighlightSnapshot: Failed to open the store:", opened)
		return false
	end
	if not opened then
		logger.err("Crossbill HighlightSnapshot: The store refused to open")
		return false
	end

	self._initialized = true
	logger.dbg("Crossbill HighlightSnapshot: Ledger open")
	return true
end

--- Close the ledger's storage
function HighlightSnapshot:close()
	if not self._initialized then
		return
	end

	local ok, err = pcall(function()
		self.store:close()
	end)
	if not ok then
		logger.warn("Crossbill HighlightSnapshot: Error closing the store:", err)
	end

	self._initialized = false
end

--- Check that a value is a whole number, as a server id always is
-- @param value any The value to test
-- @return boolean True when the value is an integer
local function isWholeNumber(value)
	return type(value) == "number" and value == math.floor(value)
end

--- Turn the importer's placed highlights into rows worth storing
-- A highlight the ledger cannot identify -- no server id, or no text to hash --
-- is dropped rather than stored half-known, since a row that matches nothing
-- would read as a device deletion later on.
-- @param placed table Array of {server_id, text} the importer put in the book
-- @return table Array of {server_id, text_hash}, in the order they were placed
local function buildRows(placed)
	local rows = {}

	for _, item in ipairs(placed) do
		local text_hash = HighlightSnapshot.hashText(item.text)
		if not isWholeNumber(item.server_id) then
			logger.warn("Crossbill HighlightSnapshot: Skipping a highlight without a server id")
		elseif not text_hash then
			logger.warn("Crossbill HighlightSnapshot: Skipping highlight", item.server_id, "without text")
		else
			table.insert(rows, { server_id = item.server_id, text_hash = text_hash })
		end
	end

	return rows
end

--- Record the highlights a pull placed in a book, replacing what was there
-- The server is the master copy, so this is a wholesale rewrite of the book's
-- rows and never a merge. An empty set still enrols the book: a pull that
-- returned no highlights is a successful pull, and the book has to become
-- diffable.
-- @param client_book_id string The client book ID
-- @param placed table Array of {server_id, text} the importer put in the book
-- @return boolean Success status
function HighlightSnapshot:recordPlaced(client_book_id, placed)
	if not self._initialized then
		logger.warn("Crossbill HighlightSnapshot: Cannot record - the ledger is not open")
		return false
	end

	if type(client_book_id) ~= "string" or client_book_id == "" then
		logger.warn("Crossbill HighlightSnapshot: Cannot record without a book id")
		return false
	end

	if type(placed) ~= "table" then
		logger.warn("Crossbill HighlightSnapshot: Cannot record a placed set that is not a list")
		return false
	end

	local rows = buildRows(placed)

	local ok, stored = pcall(function()
		return self.store:replaceBook(client_book_id, rows)
	end)

	if not ok then
		logger.err("Crossbill HighlightSnapshot: Failed to record the snapshot:", stored)
		return false
	end

	logger.dbg("Crossbill HighlightSnapshot: Recorded", #rows, "highlights for", client_book_id)
	return stored == true
end

--- Read the snapshot recorded for a book
-- @param client_book_id string The client book ID
-- @return table|nil Array of {server_id, text_hash}, empty when the book is
--   enrolled with no highlights, nil when it was never recorded
function HighlightSnapshot:getBook(client_book_id)
	if not self._initialized or type(client_book_id) ~= "string" or client_book_id == "" then
		return nil
	end

	local ok, rows = pcall(function()
		return self.store:getBook(client_book_id)
	end)

	if not ok then
		logger.err("Crossbill HighlightSnapshot: Failed to read the snapshot:", rows)
		return nil
	end

	return rows
end

--- Check whether a book has a snapshot at all
-- Distinct from an empty snapshot: a book that never pulled has nothing to diff
-- against, while a book enrolled with no highlights has an empty server copy.
-- @param client_book_id string The client book ID
-- @return boolean True when the book is enrolled
function HighlightSnapshot:hasBook(client_book_id)
	if not self._initialized or type(client_book_id) ~= "string" or client_book_id == "" then
		return false
	end

	local ok, has = pcall(function()
		return self.store:hasBook(client_book_id)
	end)

	if not ok then
		logger.err("Crossbill HighlightSnapshot: Failed to read the snapshot:", has)
		return false
	end

	return has == true
end

--- Diff a book's recorded highlights against the ones now on the device
-- Matching is by text hash and set-based: a recorded highlight counts as gone
-- only when no device highlight carries its text at all. The server's identity
-- for a highlight is that same content hash, so it cannot hold two highlights
-- with one text -- counting occurrences would only ever remove a highlight the
-- reader still has.
-- @param rows table Array of {server_id, text_hash} recorded for the book
-- @param highlights table Array of the highlights currently on the device
-- @return table {ids, mass_removal} as described on findRemoved
local function diffRows(rows, highlights)
	local on_device = {}
	local device_count = 0

	for _, highlight in ipairs(highlights) do
		local text_hash = HighlightSnapshot.hashText(highlight.text)
		if text_hash then
			on_device[text_hash] = true
			device_count = device_count + 1
		end
	end

	local ids = {}
	for _, row in ipairs(rows) do
		if not on_device[row.text_hash] then
			table.insert(ids, row.server_id)
		end
	end

	return {
		ids = ids,
		-- Every recorded highlight gone and nothing left on the device is the
		-- signature of a lost or emptied sidecar, not of a reader deleting
		-- them one by one. The caller asks before acting on it.
		mass_removal = #ids > 0 and #ids == #rows and device_count == 0,
	}
end

--- Work out which of a book's highlights the reader deleted on the device
-- A book with no snapshot cannot be diffed -- it has never pulled, so nothing
-- says whether a missing highlight was deleted here or never arrived.
-- @param client_book_id string The client book ID
-- @param highlights table|nil The highlights currently on the device
-- @return table|nil {ids = array of server ids to remove, mass_removal =
--   boolean}, or nil when the book has no snapshot to diff against
function HighlightSnapshot:findRemoved(client_book_id, highlights)
	local rows = self:getBook(client_book_id)
	if not rows then
		return nil
	end

	if type(highlights) ~= "table" then
		logger.warn("Crossbill HighlightSnapshot: Cannot diff a highlight set that is not a list")
		return nil
	end

	return diffRows(rows, highlights)
end

return HighlightSnapshot
