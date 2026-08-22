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
"title|author") rather than by the file path: the pull is the same for every copy
of a book, because the server is the master and hands each of them the same
highlights.

The removal diff is not. It asks what THIS file has lost since THIS file last
pulled, and each copy of a book carries its own KOReader sidecar, so diffing one
file's highlights against another's snapshot reads the other copy's highlights as
deletions made here (#609). Every snapshot therefore records the hash of the file
that wrote it, and `findRemoved` and `flagNew` refuse a book owned by another
file -- exactly as they refuse a book that has never pulled. The same sync's pull
re-stamps the ownership, so a refused diff costs one sync and never a highlight.
A refused flagNew is not as free: the unflagged push cannot revive a highlight
the server had deleted under the same text, and that sync's pull then drops it
from the device -- the never-pulled behaviour from before #602, accepted here
because flagging against another copy's snapshot would revive highlights the
reader deleted on the web.

The owner is the hash of the file's path, the identity SessionTracker already
uses. Hashing the file's content instead would not do: two byte-identical copies
in different folders still hold independent sidecars, so they would share an
owner and recreate the bug. A moved file is the price -- it finds its book owned
by the old path, refuses one diff, and owns the snapshot again after that sync's
pull.

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

--- Check that a value is a usable hash, as an identity always is
-- @param value any The value to test
-- @return boolean True when the value is a non-empty string
local function isHash(value)
	return type(value) == "string" and value ~= ""
end

--- Record the highlights a pull placed in a book, replacing what was there
-- The server is the master copy, so this is a wholesale rewrite of the book's
-- rows and never a merge. An empty set still enrols the book: a pull that
-- returned no highlights is a successful pull, and the book has to become
-- diffable.
--
-- The recording file takes ownership of the snapshot, taking it over from
-- whichever copy of the book held it before. A pull that cannot say which file
-- it went into is still recorded, only unowned: bookkeeping must never block a
-- pull, and the book simply stays undiffable until a pull carries a hash.
--
-- @param client_book_id string The client book ID
-- @param placed table Array of {server_id, text} the importer put in the book
-- @param book_file_hash string|nil Hash of the file the pull was applied to
-- @return boolean Success status
function HighlightSnapshot:recordPlaced(client_book_id, placed, book_file_hash)
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

	if not isHash(book_file_hash) then
		logger.warn("Crossbill HighlightSnapshot: Recording", client_book_id, "without an owning file")
		book_file_hash = nil
	end

	local rows = buildRows(placed)

	local ok, stored = pcall(function()
		return self.store:replaceBook(client_book_id, rows, book_file_hash)
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

--- Read the hash of the file that recorded a book's snapshot
-- @param client_book_id string The client book ID
-- @return string|nil The file hash, nil when the book is absent or was
--   recorded without one (a snapshot from before ownership was tracked)
function HighlightSnapshot:getBookFileHash(client_book_id)
	if not self._initialized or type(client_book_id) ~= "string" or client_book_id == "" then
		return nil
	end

	local ok, hash = pcall(function()
		return self.store:getBookFileHash(client_book_id)
	end)

	if not ok then
		logger.err("Crossbill HighlightSnapshot: Failed to read the snapshot's owner:", hash)
		return nil
	end

	return isHash(hash) and hash or nil
end

--- Check whether the given file is the one that recorded a book's snapshot
-- A snapshot another copy of the book wrote says nothing about this file, and
-- neither does one written before ownership was tracked. Both are as undiffable
-- as a book that has never pulled, and the next pull settles the question by
-- taking ownership.
-- @param client_book_id string The client book ID
-- @param book_file_hash string|nil Hash of the file being synced
-- @return boolean True when this file owns the snapshot
function HighlightSnapshot:_ownsSnapshot(client_book_id, book_file_hash)
	if not isHash(book_file_hash) then
		return false
	end

	local owner = self:getBookFileHash(client_book_id)
	if not owner then
		return false
	end

	return owner == book_file_hash
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

	for _, highlight in ipairs(highlights) do
		local text_hash = HighlightSnapshot.hashText(highlight.text)
		if text_hash then
			on_device[text_hash] = true
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
		-- Losing every recorded highlight at once rarely means the reader
		-- deleted them one by one. It is equally the signature of a lost or
		-- rebuilt sidecar under the same path, which ownership cannot catch:
		-- the file still owns its snapshot, it has simply forgotten what it
		-- pulled. What the device still has of its own says nothing either way,
		-- so the caller asks.
		mass_removal = #ids > 0 and #ids == #rows,
	}
end

--- Work out which of a book's highlights the reader deleted on the device
-- A book with no snapshot cannot be diffed -- it has never pulled, so nothing
-- says whether a missing highlight was deleted here or never arrived. Neither
-- can a book whose snapshot another copy of it recorded: what that copy pulled
-- says nothing about what this file ever held.
-- @param client_book_id string The client book ID
-- @param highlights table|nil The highlights currently on the device
-- @param book_file_hash string|nil Hash of the file being synced
-- @return table|nil {ids = array of server ids to remove, mass_removal =
--   boolean}, or nil when there is no snapshot of this file to diff against
function HighlightSnapshot:findRemoved(client_book_id, highlights, book_file_hash)
	local rows = self:getBook(client_book_id)
	if not rows then
		return nil
	end

	if not self:_ownsSnapshot(client_book_id, book_file_hash) then
		logger.dbg("Crossbill HighlightSnapshot: Not diffing", client_book_id, "against another file's snapshot")
		return nil
	end

	if type(highlights) ~= "table" then
		logger.warn("Crossbill HighlightSnapshot: Cannot diff a highlight set that is not a list")
		return nil
	end

	return diffRows(rows, highlights)
end

--- Mark the highlights this device made since its last pull
-- A highlight whose text the snapshot does not hold has never come from the
-- server, so pushing it is a deliberate act: the server takes the flag as leave
-- to revive a highlight it had removed or soft-deleted under that same text.
--
-- A book with no snapshot is left unflagged. Its sidecar may predate everything
-- the account has since deleted on the web, and flagging it blind would revive
-- all of it on the book's first sync from a fresh device. The book enrols on its
-- first pull and flags normally from then on.
--
-- A snapshot another copy of the book recorded is no better than none: this
-- file's highlights are stale against it, so every one the other copy does not
-- hold would go out flagged and tell the server to revive highlights the reader
-- deleted on the web. Pushing them unflagged is the behaviour that shipped
-- before the flag existed, and it loses nothing but a sync's delay.
--
-- @param client_book_id string The client book ID
-- @param highlights table|nil The highlights about to be pushed, flagged in place
-- @param book_file_hash string|nil Hash of the file being synced
-- @return number How many highlights were flagged
function HighlightSnapshot:flagNew(client_book_id, highlights, book_file_hash)
	local rows = self:getBook(client_book_id)
	if not rows then
		return 0
	end

	if not self:_ownsSnapshot(client_book_id, book_file_hash) then
		logger.dbg("Crossbill HighlightSnapshot: Not flagging", client_book_id, "against another file's snapshot")
		return 0
	end

	if type(highlights) ~= "table" then
		logger.warn("Crossbill HighlightSnapshot: Cannot flag a highlight set that is not a list")
		return 0
	end

	local from_server = {}
	for _, row in ipairs(rows) do
		from_server[row.text_hash] = true
	end

	local flagged = 0
	for _, highlight in ipairs(highlights) do
		local text_hash = HighlightSnapshot.hashText(highlight.text)
		-- Text the server could not have hashed has no identity to compare, and
		-- the server cannot match it to anything either, so it stays unflagged.
		if text_hash and not from_server[text_hash] then
			highlight.is_new = true
			flagged = flagged + 1
		end
	end

	logger.dbg("Crossbill HighlightSnapshot: Flagged", flagged, "new highlights for", client_book_id)
	return flagged
end

return HighlightSnapshot
