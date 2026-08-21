--[[
Highlight Snapshot Store for Crossbill Sync

The SQLite half of `modules/highlight_snapshot`: it keeps the rows and knows
nothing about what they mean. Connection, WAL and lifecycle follow SessionTracker
and DigestCache, in their own database file.

`highlight_snapshot_book` exists so that a book enrolled with an empty server
copy reads differently from a book that never pulled -- the same job
`digest_fetch_meta` does for DigestCache. Rows alone cannot say it.

The ledger takes this store as a dependency rather than requiring it, so specs
can stand in an in-memory store instead of the reader's SQLite binding.
]]

local logger = require("logger")
local SQ3 = require("lua-ljsqlite3/init")

local HighlightSnapshotStore = {}
HighlightSnapshotStore.__index = HighlightSnapshotStore

-- Constants
local DB_FILENAME = "crossbill_highlights.sqlite3"

-- Database schema
-- The primary key is (client_book_id, server_id) rather than the hash: two
-- server highlights can carry the same text, and each still needs its own row
-- so its id can be sent to the removal endpoint.
local SCHEMA = [[
CREATE TABLE IF NOT EXISTS highlight_snapshot (
    client_book_id TEXT NOT NULL,
    server_id      INTEGER NOT NULL,
    text_hash      TEXT NOT NULL,
    PRIMARY KEY (client_book_id, server_id)
);

CREATE INDEX IF NOT EXISTS idx_highlight_snapshot_hash
    ON highlight_snapshot(client_book_id, text_hash);

CREATE TABLE IF NOT EXISTS highlight_snapshot_book (
    client_book_id TEXT PRIMARY KEY,
    updated_at     INTEGER NOT NULL,
    item_count     INTEGER NOT NULL
);
]]

--- Create a new HighlightSnapshotStore instance
-- @return HighlightSnapshotStore instance
function HighlightSnapshotStore:new()
	local instance = setmetatable({}, HighlightSnapshotStore)
	instance.db = nil
	instance.db_path = nil
	instance._initialized = false
	return instance
end

--- Open the database, creating it and its schema when needed
-- @param data_dir string Path to KOReader's settings directory
-- @return boolean Success status
function HighlightSnapshotStore:open(data_dir)
	if self._initialized then
		return true
	end

	self.db_path = data_dir .. "/" .. DB_FILENAME
	logger.dbg("Crossbill HighlightSnapshotStore: Initializing database at", self.db_path)

	local success, err = pcall(function()
		self.db = SQ3.open(self.db_path)
		-- Enable WAL mode for better performance
		self.db:exec("PRAGMA journal_mode=WAL;")
		-- Create schema
		self.db:exec(SCHEMA)
	end)

	if not success then
		logger.err("Crossbill HighlightSnapshotStore: Failed to initialize database:", err)
		self.db = nil
		return false
	end

	self._initialized = true
	return true
end

--- Close the database connection
function HighlightSnapshotStore:close()
	if self.db then
		logger.dbg("Crossbill HighlightSnapshotStore: Closing database")
		local success, err = pcall(function()
			-- Checkpoint WAL to ensure all data is written to main file
			self.db:exec("PRAGMA wal_checkpoint(TRUNCATE);")
			self.db:close()
		end)
		if not success then
			logger.warn("Crossbill HighlightSnapshotStore: Error closing database:", err)
		end
		self.db = nil
	end
	self._initialized = false
end

--- Replace a book's rows with the given set, in one transaction
-- Also stamps the book as enrolled, which is what tells an empty snapshot from
-- an absent one.
-- @param client_book_id string The client book ID
-- @param rows table Array of {server_id, text_hash}
-- @return boolean Success status
function HighlightSnapshotStore:replaceBook(client_book_id, rows)
	if not self._initialized or not self.db then
		logger.warn("Crossbill HighlightSnapshotStore: Cannot replace book - database not available")
		return false
	end

	rows = rows or {}

	local success, err = pcall(function()
		self.db:exec("BEGIN TRANSACTION;")

		local del_stmt = self.db:prepare("DELETE FROM highlight_snapshot WHERE client_book_id = ?")
		del_stmt:bind(client_book_id)
		del_stmt:step()
		del_stmt:close()

		-- INSERT OR REPLACE: a server that sent the same id twice would
		-- otherwise break the primary key and abort the whole snapshot.
		local ins_stmt = self.db:prepare([[
            INSERT OR REPLACE INTO highlight_snapshot (
                client_book_id, server_id, text_hash
            ) VALUES (?, ?, ?)
        ]])

		for _, row in ipairs(rows) do
			ins_stmt:reset()
			ins_stmt:bind(client_book_id, row.server_id, row.text_hash)
			ins_stmt:step()
		end

		ins_stmt:close()

		local meta_stmt = self.db:prepare([[
            INSERT OR REPLACE INTO highlight_snapshot_book (
                client_book_id, updated_at, item_count
            ) VALUES (?, ?, ?)
        ]])
		meta_stmt:bind(client_book_id, os.time(), #rows)
		meta_stmt:step()
		meta_stmt:close()

		self.db:exec("COMMIT;")
	end)

	if not success then
		logger.err("Crossbill HighlightSnapshotStore: Failed to replace book, rolling back:", err)
		pcall(function()
			self.db:exec("ROLLBACK;")
		end)
		return false
	end

	return true
end

--- Read a book's rows
-- Ordered by server id so a read is reproducible; the order carries no meaning.
-- @param client_book_id string The client book ID
-- @return table|nil Array of {server_id, text_hash}, nil when the book was
--   never recorded
function HighlightSnapshotStore:getBook(client_book_id)
	if not self:hasBook(client_book_id) then
		return nil
	end

	local rows = {}
	local success, err = pcall(function()
		local stmt = self.db:prepare([[
            SELECT server_id, text_hash
            FROM highlight_snapshot
            WHERE client_book_id = ?
            ORDER BY server_id ASC
        ]])

		stmt:bind(client_book_id)

		for row in stmt:rows() do
			table.insert(rows, {
				server_id = tonumber(row[1]),
				text_hash = row[2],
			})
		end
		stmt:close()
	end)

	if not success then
		logger.err("Crossbill HighlightSnapshotStore: Error reading a book's snapshot:", err)
		return nil
	end

	return rows
end

--- Check whether a book has been recorded at all
-- @param client_book_id string The client book ID
-- @return boolean True when the book is enrolled
function HighlightSnapshotStore:hasBook(client_book_id)
	if not self._initialized or not self.db then
		return false
	end

	if not client_book_id then
		return false
	end

	local has = false
	local success, err = pcall(function()
		local stmt = self.db:prepare("SELECT 1 FROM highlight_snapshot_book WHERE client_book_id = ? LIMIT 1")
		stmt:bind(client_book_id)
		for _ in stmt:rows() do
			has = true
		end
		stmt:close()
	end)

	if not success then
		logger.err("Crossbill HighlightSnapshotStore: Error checking book presence:", err)
		return false
	end

	return has
end

return HighlightSnapshotStore
