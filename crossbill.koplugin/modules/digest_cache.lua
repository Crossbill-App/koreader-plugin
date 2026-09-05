--[[
Digest Cache Module for Crossbill Sync

Caches per-chapter digests (summary, key points, questions) so they can be
viewed offline. The connection, its WAL and its lifecycle belong to
`modules/sqlite_store`; what is left here is the schema, the queries and the
JSON columns the API's arrays are folded into.
]]

local Log = require("modules/log")
local log = Log.forModule("DigestCache")
local JSON = require("json")
local PluginIdentity = require("modules/plugin_identity")
local SqliteStore = require("modules/sqlite_store")

local DigestCache = {}
DigestCache.__index = DigestCache

-- Constants
-- Named after the plugin, so the side-by-side test build writes its own
-- database rather than the reader's (see modules/plugin_identity.lua)
local DB_FILENAME = PluginIdentity.namespace .. "_digests.sqlite3"

-- Database schema
local SCHEMA = [[
CREATE TABLE IF NOT EXISTS digest (
    client_book_id TEXT NOT NULL,
    chapter_number INTEGER NOT NULL,
    chapter_name   TEXT NOT NULL,
    parent_chapter_name TEXT,
    summary        TEXT,
    keypoints      TEXT,
    questions      TEXT,
    generated_at   TEXT,
    fetched_at     INTEGER NOT NULL,
    PRIMARY KEY (client_book_id, chapter_number)
);

CREATE INDEX IF NOT EXISTS idx_digest_book ON digest(client_book_id);

CREATE TABLE IF NOT EXISTS digest_fetch_meta (
    client_book_id TEXT PRIMARY KEY,
    fetched_at     INTEGER NOT NULL,
    item_count     INTEGER NOT NULL
);
]]

local DELETE_BOOK = "DELETE FROM digest WHERE client_book_id = ?"

-- INSERT OR REPLACE: two items can share a chapter_number, which would
-- otherwise break the primary key and abort the whole fetch.
local INSERT_ITEM = [[
INSERT OR REPLACE INTO digest (
    client_book_id, chapter_number, chapter_name, parent_chapter_name,
    summary, keypoints, questions, generated_at, fetched_at
) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
]]

local INSERT_FETCH_META = [[
INSERT OR REPLACE INTO digest_fetch_meta (
    client_book_id, fetched_at, item_count
) VALUES (?, ?, ?)
]]

local SELECT_BOOK = [[
SELECT chapter_number, chapter_name, parent_chapter_name,
       summary, keypoints, questions, generated_at
FROM digest
WHERE client_book_id = ?
ORDER BY chapter_number ASC
]]

local SELECT_HAS_BOOK = "SELECT 1 FROM digest_fetch_meta WHERE client_book_id = ? LIMIT 1"

local SELECT_FETCHED_AT = "SELECT fetched_at FROM digest_fetch_meta WHERE client_book_id = ? LIMIT 1"

--- Create a new DigestCache instance
-- @return DigestCache instance
function DigestCache:new()
	local instance = setmetatable({}, DigestCache)
	instance.store = SqliteStore:new("DigestCache")
	return instance
end

--- Initialize the cache with its database
-- @param data_dir string Path to KOReader settings directory
-- @return boolean Success status
function DigestCache:init(data_dir)
	return self.store:open(data_dir .. "/" .. DB_FILENAME, SCHEMA)
end

--- Close the database connection
function DigestCache:close()
	self.store:close()
end

--- Coerce a decoded JSON value to a string, treating anything else as nil.
-- JSON null decodes to a non-nil sentinel value (not Lua nil) in KOReader's
-- JSON library; binding such a sentinel into SQLite raises an error, so all
-- nullable fields must pass through this before binding.
-- @param value any A value from a decoded JSON response
-- @return string|nil The string value, or nil for null/absent/non-string
local function asText(value)
	if type(value) == "string" then
		return value
	end
	return nil
end

--- Encode an array of strings to a JSON string, defaulting to an empty array
-- Non-string elements (e.g. JSON null sentinels) are dropped.
-- @param value table|nil The array to encode
-- @return string JSON-encoded array
local function encodeArray(value)
	if type(value) ~= "table" then
		return "[]"
	end
	local strings = {}
	for _, element in ipairs(value) do
		local text = asText(element)
		if text then
			table.insert(strings, text)
		end
	end
	if #strings == 0 then
		return "[]"
	end
	local ok, encoded = pcall(JSON.encode, strings)
	if ok and encoded then
		return encoded
	end
	return "[]"
end

--- Decode a JSON array string back to a Lua array, defaulting to empty
-- @param text string|nil The JSON-encoded array
-- @return table The decoded array (never nil)
local function decodeArray(text)
	if type(text) ~= "string" or text == "" then
		return {}
	end
	local ok, decoded = pcall(JSON.decode, text)
	if ok and type(decoded) == "table" then
		return decoded
	end
	return {}
end

--- Replace a book's cached digests with a fresh set of items
-- Deletes existing rows and inserts the new ones in a single transaction.
-- Individual items are inserted defensively: the server can return two items
-- with the same chapter_number, and a single failing item must not roll back
-- the whole book and leave the cache permanently stale. Only a failure of the
-- delete or of the fetch-meta row -- which the whole book's freshness rests on
-- -- rolls the transaction back.
-- @param client_book_id string The client book ID
-- @param items table Array of digest items from the API
-- @return boolean Success status
function DigestCache:replaceBook(client_book_id, items)
	if not client_book_id then
		log.warn("Cannot replace book - missing client_book_id")
		return false
	end

	items = items or {}
	local fetched_at = os.time()
	local inserted_count = 0
	local failed_count = 0

	local success = self.store:transaction(function(db)
		if not db:exec(DELETE_BOOK, SqliteStore.binds(client_book_id)) then
			return false
		end

		for _, item in ipairs(items) do
			local chapter_number = tonumber(item.chapter_number)
			if chapter_number == nil then
				-- The primary key requires an integer chapter_number; skip defensively.
				log.warn("Skipping item with nil chapter_number for chapter", tostring(item.chapter_name))
				failed_count = failed_count + 1
			else
				local inserted = db:exec(
					INSERT_ITEM,
					SqliteStore.binds(
						client_book_id,
						chapter_number,
						asText(item.chapter_name) or "",
						asText(item.parent_chapter_name),
						asText(item.summary) or "",
						encodeArray(item.keypoints),
						encodeArray(item.questions),
						asText(item.generated_at),
						fetched_at
					)
				)

				if inserted then
					inserted_count = inserted_count + 1
				else
					failed_count = failed_count + 1
					log.err(
						"Failed to cache digest item for book",
						tostring(client_book_id),
						"chapter",
						tostring(chapter_number),
						tostring(item.chapter_name)
					)
				end
			end
		end

		-- Record this fetch so a "fetched and empty" book is distinguishable from
		-- a "never fetched" one. hasBook checks this meta table, so a book with an
		-- empty server digest list still counts as present and does not trigger
		-- a re-fetch on every popup open. An empty fetch is refreshed by sync
		-- (refreshBook) or, once it is old enough, by a popup open (getFetchedAt).
		return db:exec(INSERT_FETCH_META, SqliteStore.binds(client_book_id, fetched_at, inserted_count))
	end)

	if not success then
		return false
	end

	if failed_count > 0 then
		log.warn(
			"cached",
			inserted_count,
			"of",
			#items,
			"digest items;",
			failed_count,
			"failed for book",
			tostring(client_book_id)
		)
	end

	log.dbg("Replaced digests for book", client_book_id)
	return true
end

--- Get all cached digest items for a book, ordered by chapter_number
-- @param client_book_id string The client book ID
-- @return table Array of decoded digest items
function DigestCache:getBook(client_book_id)
	if not client_book_id then
		return {}
	end

	local items = self.store:query(SELECT_BOOK, SqliteStore.binds(client_book_id), function(row)
		return {
			chapter_number = tonumber(row[1]),
			chapter_name = row[2],
			parent_chapter_name = row[3],
			summary = row[4],
			keypoints = decodeArray(row[5]),
			questions = decodeArray(row[6]),
			generated_at = row[7],
		}
	end)

	return items or {}
end

--- Check whether a book has ever been fetched (even if it had no digests)
-- Checks the fetch-meta table rather than counting digest rows, so a book
-- whose server digest list was empty still counts as present. This keeps a
-- popup open from re-attempting a network fetch every time; an empty fetch is
-- only retried once it is stale (see getFetchedAt).
-- @param client_book_id string The client book ID
-- @return boolean True if the book has been fetched at least once
function DigestCache:hasBook(client_book_id)
	if not client_book_id then
		return false
	end

	local rows = self.store:query(SELECT_HAS_BOOK, SqliteStore.binds(client_book_id), function()
		return true
	end)

	return rows ~= nil and #rows > 0
end

--- Get the time of a book's last digest fetch
-- @param client_book_id string The client book ID
-- @return number|nil Unix time of the last fetch, or nil if never fetched
function DigestCache:getFetchedAt(client_book_id)
	if not client_book_id then
		return nil
	end

	local rows = self.store:query(SELECT_FETCHED_AT, SqliteStore.binds(client_book_id), function(row)
		return tonumber(row[1])
	end)

	return rows and rows[1] or nil
end

return DigestCache
