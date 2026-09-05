--[[
In-memory stand-in for the session tracker's SQLite store.

`modules/session_store` talks to `lua-ljsqlite3`, which does not exist outside
KOReader, so the tracker takes its store as a dependency and specs hand it this
one. It implements the same contract: a saved session keeps the columns it was
given, `getUnsyncedSessionsForBook` answers a book's sessions oldest first --
carrying only the columns the upload sends, the way the real query does -- and
one marked synced stops being answered.

Follows `spec/support/fake_snapshot_store.lua`, down to `fails_at` for the tests
that need a store to misbehave.
]]

local FakeSessionStore = {}
FakeSessionStore.__index = FakeSessionStore

--- Create a store that keeps its sessions in a table
-- @return FakeSessionStore instance
function FakeSessionStore:new()
	return setmetatable({
		-- Saved sessions, in the order they were saved, each with the id the
		-- store handed it.
		sessions = {},
		prepared = false,
		closed = false,
		next_id = 1,
		-- Set to "prepare", "saveSession" or "markSessionsSynced" to make that
		-- call misbehave.
		fails_at = nil,
	}, FakeSessionStore)
end

--- Copy a session so the caller cannot mutate what was stored
-- @param session table The session's columns
-- @return table A fresh table with the same columns
local function copySession(session)
	local copied = {}
	for key, value in pairs(session) do
		copied[key] = value
	end
	return copied
end

--- Create the store's tables in the database it was given
-- @return boolean Success status
function FakeSessionStore:prepare()
	if self.fails_at == "prepare" then
		return false
	end
	self.prepared = true
	return true
end

--- Save one finished session
-- @param session table The session's columns
-- @return boolean Success status
function FakeSessionStore:saveSession(session)
	if self.fails_at == "saveSession" then
		error("session store exploded")
	end

	local stored = copySession(session)
	stored.id = self.next_id
	stored.synced = false
	self.next_id = self.next_id + 1
	table.insert(self.sessions, stored)

	return true
end

-- What `SessionStore:getUnsyncedSessionsForBook` selects: the columns the
-- upload sends, plus the id the sync marks them synced by.
local UNSYNCED_COLUMNS = {
	"id",
	"start_time",
	"end_time",
	"position_type",
	"start_position",
	"end_position",
	"start_page",
	"end_page",
	"device_id",
}

--- Read a book's sessions that have not been marked synced
-- @param book_file_hash string Hash of the book file path
-- @return table Array of session records, oldest first
function FakeSessionStore:getUnsyncedSessionsForBook(book_file_hash)
	local found = {}
	for _, session in ipairs(self.sessions) do
		if session.book_hash == book_file_hash and not session.synced then
			local record = {}
			for _, column in ipairs(UNSYNCED_COLUMNS) do
				record[column] = session[column]
			end
			table.insert(found, record)
		end
	end
	return found
end

--- Mark sessions as synced
-- @param session_ids table Array of session IDs
-- @return boolean Success status
function FakeSessionStore:markSessionsSynced(session_ids)
	if self.fails_at == "markSessionsSynced" then
		return false
	end

	for _, id in ipairs(session_ids or {}) do
		for _, session in ipairs(self.sessions) do
			if session.id == id then
				session.synced = true
			end
		end
	end

	return true
end

--- Close the store
function FakeSessionStore:close()
	self.closed = true
end

return FakeSessionStore
