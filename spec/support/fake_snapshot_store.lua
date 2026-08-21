--[[
In-memory stand-in for the snapshot ledger's SQLite store.

`modules/highlight_snapshot_store` talks to `lua-ljsqlite3`, which does not
exist outside KOReader, so the ledger takes its store as a dependency and specs
hand it this one. It implements the same contract, including the distinction the
ledger relies on: `getBook` answers nil for a book that was never recorded and an
empty list for a book enrolled with no highlights.
]]

local FakeSnapshotStore = {}
FakeSnapshotStore.__index = FakeSnapshotStore

--- Create a store that keeps its rows in a table
-- @return FakeSnapshotStore instance
function FakeSnapshotStore:new()
	return setmetatable({
		books = {},
		opened_with = nil,
		closed = false,
		-- Set to "open" or "replaceBook" to make that call misbehave.
		fails_at = nil,
	}, FakeSnapshotStore)
end

--- Copy a row array so the caller cannot mutate what was stored
-- @param rows table Array of {server_id, text_hash}
-- @return table A fresh array of fresh rows
local function copyRows(rows)
	local copied = {}
	for i, row in ipairs(rows) do
		copied[i] = { server_id = row.server_id, text_hash = row.text_hash }
	end
	return copied
end

--- Open the store
-- @param data_dir string Directory the database would live in
-- @return boolean Success status
function FakeSnapshotStore:open(data_dir)
	if self.fails_at == "open" then
		return false
	end
	self.opened_with = data_dir
	return true
end

--- Replace a book's rows wholesale
-- @param client_book_id string The client book ID
-- @param rows table Array of {server_id, text_hash}
-- @return boolean Success status
function FakeSnapshotStore:replaceBook(client_book_id, rows)
	if self.fails_at == "replaceBook" then
		error("snapshot store exploded")
	end
	self.books[client_book_id] = copyRows(rows)
	return true
end

--- Read a book's rows
-- @param client_book_id string The client book ID
-- @return table|nil Array of {server_id, text_hash}, nil when never recorded
function FakeSnapshotStore:getBook(client_book_id)
	local rows = self.books[client_book_id]
	if not rows then
		return nil
	end
	return copyRows(rows)
end

--- Check whether a book has been recorded at all
-- @param client_book_id string The client book ID
-- @return boolean True when the book is enrolled
function FakeSnapshotStore:hasBook(client_book_id)
	return self.books[client_book_id] ~= nil
end

--- Close the store
function FakeSnapshotStore:close()
	self.closed = true
end

return FakeSnapshotStore
