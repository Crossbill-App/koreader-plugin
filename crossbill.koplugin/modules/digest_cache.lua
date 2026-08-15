--[[
Digest Cache Module for Crossbill Sync

Caches per-chapter digests (summary, key points, questions) in a
local SQLite3 database so it can be viewed offline. Mirrors the connection,
WAL and lifecycle patterns used by SessionTracker, but stores its data in its
own database file.
]]

local logger = require("logger")
local SQ3 = require("lua-ljsqlite3/init")
local JSON = require("json")

local DigestCache = {}
DigestCache.__index = DigestCache

-- Constants
local DB_FILENAME = "crossbill_digests.sqlite3"

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

--- Create a new DigestCache instance
-- @param settings Settings instance for accessing configuration
-- @return DigestCache instance
function DigestCache:new(settings)
	local instance = setmetatable({}, DigestCache)
	instance.db = nil
	instance.db_path = nil
	instance._initialized = false
	instance.settings = settings
	return instance
end

--- Initialize the cache with its database
-- @param data_dir string Path to KOReader settings directory
-- @return boolean Success status
function DigestCache:init(data_dir)
	if self._initialized then
		return true
	end

	self.db_path = data_dir .. "/" .. DB_FILENAME
	logger.dbg("Crossbill DigestCache: Initializing database at", self.db_path)

	local success, err = pcall(function()
		self.db = SQ3.open(self.db_path)
		-- Enable WAL mode for better performance
		self.db:exec("PRAGMA journal_mode=WAL;")
		-- Create schema
		self.db:exec(SCHEMA)
	end)

	if not success then
		logger.err("Crossbill DigestCache: Failed to initialize database:", err)
		self.db = nil
		return false
	end

	self._initialized = true
	logger.dbg("Crossbill DigestCache: Database initialized successfully")
	return true
end

--- Close the database connection
function DigestCache:close()
	if self.db then
		logger.dbg("Crossbill DigestCache: Closing database")
		local success, err = pcall(function()
			-- Checkpoint WAL to ensure all data is written to main file
			self.db:exec("PRAGMA wal_checkpoint(TRUNCATE);")
			self.db:close()
		end)
		if not success then
			logger.warn("Crossbill DigestCache: Error closing database:", err)
		end
		self.db = nil
	end
	self._initialized = false
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
-- the whole book and leave the cache permanently stale. Items are upserted and
-- each one is guarded on its own; only a transaction-level failure rolls back.
-- @param client_book_id string The client book ID
-- @param items table Array of digest items from the API
-- @return boolean Success status
function DigestCache:replaceBook(client_book_id, items)
	if not self._initialized or not self.db then
		logger.warn("Crossbill DigestCache: Cannot replace book - not initialized")
		return false
	end

	if not client_book_id then
		logger.warn("Crossbill DigestCache: Cannot replace book - missing client_book_id")
		return false
	end

	items = items or {}
	local fetched_at = os.time()
	local inserted_count = 0
	local failed_count = 0

	local success, err = pcall(function()
		self.db:exec("BEGIN TRANSACTION;")

		local del_stmt = self.db:prepare("DELETE FROM digest WHERE client_book_id = ?")
		del_stmt:bind(client_book_id)
		del_stmt:step()
		del_stmt:close()

		-- INSERT OR REPLACE: two items can share a chapter_number, which would
		-- otherwise break the primary key and abort the whole fetch.
		local ins_stmt = self.db:prepare([[
            INSERT OR REPLACE INTO digest (
                client_book_id, chapter_number, chapter_name, parent_chapter_name,
                summary, keypoints, questions, generated_at, fetched_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
        ]])

		for _, item in ipairs(items) do
			local chapter_number = tonumber(item.chapter_number)
			if chapter_number == nil then
				-- The primary key requires an integer chapter_number; skip defensively.
				logger.warn(
					"Crossbill DigestCache: Skipping item with nil chapter_number for chapter",
					tostring(item.chapter_name)
				)
				failed_count = failed_count + 1
			else
				local item_ok, item_err = pcall(function()
					ins_stmt:reset()
					ins_stmt:bind(
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
					ins_stmt:step()
				end)

				if item_ok then
					inserted_count = inserted_count + 1
				else
					failed_count = failed_count + 1
					logger.err(
						"Crossbill DigestCache: Failed to cache digest item for book",
						tostring(client_book_id),
						"chapter",
						tostring(chapter_number),
						tostring(item.chapter_name),
						item_err
					)
					-- Leave the statement usable for the remaining items.
					pcall(function()
						ins_stmt:reset()
					end)
				end
			end
		end

		ins_stmt:close()

		-- Record this fetch so a "fetched and empty" book is distinguishable from
		-- a "never fetched" one. hasBook checks this meta table, so a book with an
		-- empty server digest list still counts as present and does not trigger
		-- a re-fetch on every popup open. An empty fetch is refreshed by sync
		-- (refreshBook) or, once it is old enough, by a popup open (getFetchedAt).
		local meta_stmt = self.db:prepare([[
            INSERT OR REPLACE INTO digest_fetch_meta (
                client_book_id, fetched_at, item_count
            ) VALUES (?, ?, ?)
        ]])
		meta_stmt:bind(client_book_id, fetched_at, inserted_count)
		meta_stmt:step()
		meta_stmt:close()

		self.db:exec("COMMIT;")
	end)

	if not success then
		logger.err("Crossbill DigestCache: Failed to replace book, rolling back:", err)
		pcall(function()
			self.db:exec("ROLLBACK;")
		end)
		return false
	end

	if failed_count > 0 then
		logger.warn(
			"Crossbill DigestCache: cached",
			inserted_count,
			"of",
			#items,
			"digest items;",
			failed_count,
			"failed for book",
			tostring(client_book_id)
		)
	end

	logger.dbg("Crossbill DigestCache: Replaced digests for book", client_book_id)
	return true
end

--- Get all cached digest items for a book, ordered by chapter_number
-- @param client_book_id string The client book ID
-- @return table Array of decoded digest items
function DigestCache:getBook(client_book_id)
	if not self._initialized or not self.db then
		return {}
	end

	if not client_book_id then
		return {}
	end

	local items = {}
	local success, err = pcall(function()
		local stmt = self.db:prepare([[
            SELECT chapter_number, chapter_name, parent_chapter_name,
                   summary, keypoints, questions, generated_at
            FROM digest
            WHERE client_book_id = ?
            ORDER BY chapter_number ASC
        ]])

		stmt:bind(client_book_id)

		for row in stmt:rows() do
			table.insert(items, {
				chapter_number = tonumber(row[1]),
				chapter_name = row[2],
				parent_chapter_name = row[3],
				summary = row[4],
				keypoints = decodeArray(row[5]),
				questions = decodeArray(row[6]),
				generated_at = row[7],
			})
		end
		stmt:close()
	end)

	if not success then
		logger.err("Crossbill DigestCache: Error fetching book digests:", err)
	end

	return items
end

--- Check whether a book has ever been fetched (even if it had no digests)
-- Checks the fetch-meta table rather than counting digest rows, so a book
-- whose server digest list was empty still counts as present. This keeps a
-- popup open from re-attempting a network fetch every time; an empty fetch is
-- only retried once it is stale (see getFetchedAt).
-- @param client_book_id string The client book ID
-- @return boolean True if the book has been fetched at least once
function DigestCache:hasBook(client_book_id)
	if not self._initialized or not self.db then
		return false
	end

	if not client_book_id then
		return false
	end

	local has = false
	local success, err = pcall(function()
		local stmt = self.db:prepare("SELECT 1 FROM digest_fetch_meta WHERE client_book_id = ? LIMIT 1")
		stmt:bind(client_book_id)
		for _ in stmt:rows() do
			has = true
		end
		stmt:close()
	end)

	if not success then
		logger.err("Crossbill DigestCache: Error checking book presence:", err)
		return false
	end

	return has
end

--- Get the time of a book's last digest fetch
-- @param client_book_id string The client book ID
-- @return number|nil Unix time of the last fetch, or nil if never fetched
function DigestCache:getFetchedAt(client_book_id)
	if not self._initialized or not self.db then
		return nil
	end

	if not client_book_id then
		return nil
	end

	local fetched_at = nil
	local success, err = pcall(function()
		local stmt = self.db:prepare("SELECT fetched_at FROM digest_fetch_meta WHERE client_book_id = ? LIMIT 1")
		stmt:bind(client_book_id)
		for row in stmt:rows() do
			fetched_at = tonumber(row[1])
		end
		stmt:close()
	end)

	if not success then
		logger.err("Crossbill DigestCache: Error reading fetch time:", err)
		return nil
	end

	return fetched_at
end

return DigestCache
