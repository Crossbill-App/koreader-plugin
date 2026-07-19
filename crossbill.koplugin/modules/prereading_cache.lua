--[[
Prereading Cache Module for Crossbill Sync

Caches per-chapter prereading content (summary, key points, questions) in a
local SQLite3 database so it can be viewed offline. Mirrors the connection,
WAL and lifecycle patterns used by SessionTracker, but stores its data in its
own database file.
]]

local logger = require("logger")
local SQ3 = require("lua-ljsqlite3/init")
local JSON = require("json")

local PrereadingCache = {}
PrereadingCache.__index = PrereadingCache

-- Constants
local DB_FILENAME = "crossbill_prereading.sqlite3"

-- Database schema
local SCHEMA = [[
CREATE TABLE IF NOT EXISTS prereading (
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

CREATE INDEX IF NOT EXISTS idx_prereading_book ON prereading(client_book_id);
]]

--- Create a new PrereadingCache instance
-- @param settings Settings instance for accessing configuration
-- @return PrereadingCache instance
function PrereadingCache:new(settings)
	local instance = setmetatable({}, PrereadingCache)
	instance.db = nil
	instance.db_path = nil
	instance._initialized = false
	instance.settings = settings
	return instance
end

--- Initialize the cache with its database
-- @param data_dir string Path to KOReader settings directory
-- @return boolean Success status
function PrereadingCache:init(data_dir)
	if self._initialized then
		return true
	end

	self.db_path = data_dir .. "/" .. DB_FILENAME
	logger.dbg("Crossbill PrereadingCache: Initializing database at", self.db_path)

	local success, err = pcall(function()
		self.db = SQ3.open(self.db_path)
		-- Enable WAL mode for better performance
		self.db:exec("PRAGMA journal_mode=WAL;")
		-- Create schema
		self.db:exec(SCHEMA)
	end)

	if not success then
		logger.err("Crossbill PrereadingCache: Failed to initialize database:", err)
		self.db = nil
		return false
	end

	self._initialized = true
	logger.dbg("Crossbill PrereadingCache: Database initialized successfully")
	return true
end

--- Close the database connection
function PrereadingCache:close()
	if self.db then
		logger.dbg("Crossbill PrereadingCache: Closing database")
		local success, err = pcall(function()
			-- Checkpoint WAL to ensure all data is written to main file
			self.db:exec("PRAGMA wal_checkpoint(TRUNCATE);")
			self.db:close()
		end)
		if not success then
			logger.warn("Crossbill PrereadingCache: Error closing database:", err)
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

--- Replace all cached prereading for a book with a fresh set of items
-- Deletes existing rows and inserts the new ones in a single transaction.
-- @param client_book_id string The client book ID
-- @param items table Array of prereading items from the API
-- @return boolean Success status
function PrereadingCache:replaceBook(client_book_id, items)
	if not self._initialized or not self.db then
		logger.warn("Crossbill PrereadingCache: Cannot replace book - not initialized")
		return false
	end

	if not client_book_id then
		logger.warn("Crossbill PrereadingCache: Cannot replace book - missing client_book_id")
		return false
	end

	items = items or {}
	local fetched_at = os.time()

	local success, err = pcall(function()
		self.db:exec("BEGIN TRANSACTION;")

		local del_stmt = self.db:prepare("DELETE FROM prereading WHERE client_book_id = ?")
		del_stmt:bind(client_book_id)
		del_stmt:step()
		del_stmt:close()

		local ins_stmt = self.db:prepare([[
            INSERT INTO prereading (
                client_book_id, chapter_number, chapter_name, parent_chapter_name,
                summary, keypoints, questions, generated_at, fetched_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
        ]])

		for _, item in ipairs(items) do
			local chapter_number = tonumber(item.chapter_number)
			if chapter_number == nil then
				-- The primary key requires an integer chapter_number; skip defensively.
				logger.warn(
					"Crossbill PrereadingCache: Skipping item with nil chapter_number for chapter",
					tostring(item.chapter_name)
				)
			else
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
			end
		end

		ins_stmt:close()
		self.db:exec("COMMIT;")
	end)

	if not success then
		logger.err("Crossbill PrereadingCache: Failed to replace book, rolling back:", err)
		pcall(function()
			self.db:exec("ROLLBACK;")
		end)
		return false
	end

	logger.dbg("Crossbill PrereadingCache: Replaced prereading for book", client_book_id)
	return true
end

--- Get all cached prereading items for a book, ordered by chapter_number
-- @param client_book_id string The client book ID
-- @return table Array of decoded prereading items
function PrereadingCache:getBook(client_book_id)
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
            FROM prereading
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
		logger.err("Crossbill PrereadingCache: Error fetching book prereading:", err)
	end

	return items
end

--- Check whether any prereading rows are cached for a book
-- @param client_book_id string The client book ID
-- @return boolean True if at least one row exists
function PrereadingCache:hasBook(client_book_id)
	if not self._initialized or not self.db then
		return false
	end

	if not client_book_id then
		return false
	end

	local has = false
	local success, err = pcall(function()
		local stmt = self.db:prepare("SELECT 1 FROM prereading WHERE client_book_id = ? LIMIT 1")
		stmt:bind(client_book_id)
		for _ in stmt:rows() do
			has = true
		end
		stmt:close()
	end)

	if not success then
		logger.err("Crossbill PrereadingCache: Error checking book presence:", err)
		return false
	end

	return has
end

return PrereadingCache
