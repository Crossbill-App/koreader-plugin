--[[
Highlight Snapshot Store for Crossbill Sync

The SQLite half of `modules/highlight_snapshot`: it keeps the rows and knows
nothing about what they mean. The connection, its WAL and its lifecycle belong
to `modules/sqlite_store`; what is left here is the schema and the queries.

`highlight_snapshot_book` exists so that a book enrolled with an empty server
copy reads differently from a book that never pulled -- the same job
`digest_fetch_meta` does for DigestCache. Rows alone cannot say it. It also
carries the hash of the file that wrote the rows, so the ledger can tell its own
snapshot from one another copy of the same book left behind.

The ledger takes this store as a dependency rather than requiring it, so specs
can stand in an in-memory store instead of the reader's SQLite binding.
]]

local SqliteStore = require("modules/sqlite_store")

local HighlightSnapshotStore = {}
HighlightSnapshotStore.__index = HighlightSnapshotStore

-- Constants
local DB_FILENAME = "crossbill_highlights.sqlite3"

-- Database schema
-- The primary key is (client_book_id, server_id) rather than the hash: two
-- server highlights can carry the same text, and each still needs its own row
-- so its id can be sent to the removal endpoint.
-- `book_file_hash` is nullable: a snapshot recorded without one belongs to no
-- file, and the ledger treats it as undiffable until a pull stamps it.
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
    item_count     INTEGER NOT NULL,
    book_file_hash TEXT
);
]]

-- A database from before per-file ownership never gets the column from the
-- schema above, which only creates the table when it is missing.
local MIGRATIONS = {
	"ALTER TABLE highlight_snapshot_book ADD COLUMN book_file_hash TEXT",
}

local DELETE_BOOK = "DELETE FROM highlight_snapshot WHERE client_book_id = ?"

-- INSERT OR REPLACE: a server that sent the same id twice would otherwise
-- break the primary key and abort the whole snapshot.
local INSERT_ROW = [[
INSERT OR REPLACE INTO highlight_snapshot (
    client_book_id, server_id, text_hash
) VALUES (?, ?, ?)
]]

local INSERT_BOOK = [[
INSERT OR REPLACE INTO highlight_snapshot_book (
    client_book_id, book_file_hash, updated_at, item_count
) VALUES (?, ?, ?, ?)
]]

-- Ordered by server id so a read is reproducible; the order carries no meaning.
local SELECT_BOOK = [[
SELECT server_id, text_hash
FROM highlight_snapshot
WHERE client_book_id = ?
ORDER BY server_id ASC
]]

local SELECT_BOOK_FILE_HASH = "SELECT book_file_hash FROM highlight_snapshot_book WHERE client_book_id = ?"

local SELECT_HAS_BOOK = "SELECT 1 FROM highlight_snapshot_book WHERE client_book_id = ? LIMIT 1"

--- Create a new HighlightSnapshotStore instance
-- @return HighlightSnapshotStore instance
function HighlightSnapshotStore:new()
	local instance = setmetatable({}, HighlightSnapshotStore)
	instance.store = SqliteStore:new("HighlightSnapshotStore")
	return instance
end

--- Open the database, creating it and its schema when needed
-- @param data_dir string Path to KOReader's settings directory
-- @return boolean Success status
function HighlightSnapshotStore:open(data_dir)
	return self.store:open(data_dir .. "/" .. DB_FILENAME, SCHEMA, MIGRATIONS)
end

--- Close the database connection
function HighlightSnapshotStore:close()
	self.store:close()
end

--- Replace a book's rows with the given set, in one transaction
-- Also stamps the book as enrolled, which is what tells an empty snapshot from
-- an absent one, and records which file wrote the rows. Every statement counts:
-- a snapshot missing a row would read as a highlight deleted on the device, so
-- one that fails takes the whole replacement down with it.
-- @param client_book_id string The client book ID
-- @param rows table Array of {server_id, text_hash}
-- @param book_file_hash string|nil Hash of the file the rows were placed in,
--   stored as NULL when absent
-- @return boolean Success status
function HighlightSnapshotStore:replaceBook(client_book_id, rows, book_file_hash)
	rows = rows or {}

	return self.store:transaction(function(db)
		if not db:exec(DELETE_BOOK, SqliteStore.binds(client_book_id)) then
			return false
		end

		for _, row in ipairs(rows) do
			if not db:exec(INSERT_ROW, SqliteStore.binds(client_book_id, row.server_id, row.text_hash)) then
				return false
			end
		end

		-- A nil book_file_hash binds as SQL NULL, which is the "no file owns
		-- this snapshot" the ledger reads back -- hence SqliteStore.binds,
		-- which counts a nil rather than stopping at it.
		return db:exec(INSERT_BOOK, SqliteStore.binds(client_book_id, book_file_hash, os.time(), #rows))
	end)
end

--- Read a book's rows
-- @param client_book_id string The client book ID
-- @return table|nil Array of {server_id, text_hash}, nil when the book was
--   never recorded
function HighlightSnapshotStore:getBook(client_book_id)
	if not self:hasBook(client_book_id) then
		return nil
	end

	return self.store:query(SELECT_BOOK, SqliteStore.binds(client_book_id), function(row)
		return {
			server_id = tonumber(row[1]),
			text_hash = row[2],
		}
	end)
end

--- Read the hash of the file that recorded a book's snapshot
-- A row written before per-file ownership existed carries NULL, which reads the
-- same as an absent book: nobody owns the snapshot, so nothing may be diffed
-- against it until a pull stamps it.
-- @param client_book_id string The client book ID
-- @return string|nil The file hash, nil when the book is absent or unstamped
function HighlightSnapshotStore:getBookFileHash(client_book_id)
	if not client_book_id then
		return nil
	end

	local hashes = self.store:query(SELECT_BOOK_FILE_HASH, SqliteStore.binds(client_book_id), function(row)
		-- A NULL column can arrive as nil or as the binding's own NULL
		-- sentinel, so only an actual string counts as an owner. Anything else
		-- maps to nil, which drops the row and reads as unstamped.
		if type(row[1]) == "string" and row[1] ~= "" then
			return row[1]
		end
		return nil
	end)

	return hashes and hashes[1] or nil
end

--- Check whether a book has been recorded at all
-- @param client_book_id string The client book ID
-- @return boolean True when the book is enrolled
function HighlightSnapshotStore:hasBook(client_book_id)
	if not client_book_id then
		return false
	end

	local rows = self.store:query(SELECT_HAS_BOOK, SqliteStore.binds(client_book_id), function()
		return true
	end)

	return rows ~= nil and #rows > 0
end

return HighlightSnapshotStore
