--[[
Session Store for Crossbill Sync

The SQLite half of `modules/sessiontracker`: finished reading sessions as rows,
each with the Page Views it recorded, and the queries the sync needs over them.
It knows nothing about when a session begins or ends, nor what a position means
-- that is the tracker's, and keeping it out of here is what lets the tracker be
tested at all.

The tracker takes this store as a dependency rather than requiring it, so specs
can hand it an in-memory stand-in instead of the reader's SQLite binding, the
way `modules/highlight_snapshot` already does.
]]

local PluginIdentity = require("modules/plugin_identity")
local SqliteStore = require("modules/sqlite_store")

local SessionStore = {}
SessionStore.__index = SessionStore

-- Constants
-- Named after the plugin, so the side-by-side test build writes its own
-- database rather than the reader's (see modules/plugin_identity.lua)
local DB_FILENAME = PluginIdentity.namespace .. "_sessions.sqlite3"

-- Database schema
local SCHEMA = [[
CREATE TABLE IF NOT EXISTS sessions (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    book_file TEXT NOT NULL,
    book_hash TEXT NOT NULL,
    book_title TEXT,
    book_author TEXT,
    start_time INTEGER NOT NULL,
    end_time INTEGER NOT NULL,
    duration_seconds INTEGER,
    position_type TEXT NOT NULL,
    start_position TEXT NOT NULL,
    end_position TEXT NOT NULL,
    start_page INTEGER,
    end_page INTEGER,
    total_pages INTEGER,
    synced INTEGER DEFAULT 0,
    created_at INTEGER DEFAULT (strftime('%s', 'now')),
    device_id TEXT
);

CREATE INDEX IF NOT EXISTS idx_sessions_book_hash ON sessions(book_hash);
CREATE INDEX IF NOT EXISTS idx_sessions_synced ON sessions(synced);
CREATE INDEX IF NOT EXISTS idx_sessions_start_time ON sessions(start_time);

CREATE TABLE IF NOT EXISTS page_views (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    session_id INTEGER NOT NULL REFERENCES sessions(id),
    start_xpoint TEXT NOT NULL,
    end_xpoint TEXT NOT NULL,
    shown_at INTEGER NOT NULL,
    duration_seconds INTEGER NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_page_views_session_id ON page_views(session_id);
]]

-- Databases made before sessions carried an author never get the column from
-- the schema above, which only creates the table when it is missing. The
-- page_views table needs no entry: it is a table of its own, so the schema
-- creates it in an older database too.
local MIGRATIONS = {
	"ALTER TABLE sessions ADD COLUMN book_author TEXT",
}

local INSERT_SESSION = [[
INSERT INTO sessions (
    book_file, book_hash, book_title, book_author,
    start_time, end_time, duration_seconds,
    position_type, start_position, end_position,
    start_page, end_page, total_pages,
    device_id
) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
]]

-- Only what the upload sends, plus the id the sync marks synced by. The rest of
-- a row is written for the record and read by nothing.
local SELECT_UNSYNCED_FOR_BOOK = [[
SELECT id, start_time, end_time,
       position_type, start_position, end_position,
       start_page, end_page, device_id
FROM sessions
WHERE book_hash = ? AND synced = 0
ORDER BY start_time ASC
]]

local INSERT_PAGE_VIEW = [[
INSERT INTO page_views (
    session_id, start_xpoint, end_xpoint, shown_at, duration_seconds
) VALUES (?, ?, ?, ?, ?)
]]

-- The Page Views of the same sessions SELECT_UNSYNCED_FOR_BOOK answers, in the
-- order they were shown.
local SELECT_UNSYNCED_PAGE_VIEWS_FOR_BOOK = [[
SELECT page_views.session_id, page_views.start_xpoint, page_views.end_xpoint,
       page_views.shown_at, page_views.duration_seconds
FROM page_views
JOIN sessions ON sessions.id = page_views.session_id
WHERE sessions.book_hash = ? AND sessions.synced = 0
ORDER BY page_views.session_id ASC, page_views.shown_at ASC, page_views.id ASC
]]

--- Build the placeholder list of an IN clause
-- @param count number How many values the clause holds
-- @return string "?,?,...", one per value
local function placeholders(count)
	return string.rep("?", count, ",")
end

--- Create a new SessionStore instance
-- @return SessionStore instance
function SessionStore:new()
	local instance = setmetatable({}, SessionStore)
	instance.store = SqliteStore:new("SessionStore")
	return instance
end

--- Open the database, creating it and its schema when needed
-- @param data_dir string Path to KOReader's settings directory
-- @return boolean Success status
function SessionStore:open(data_dir)
	return self.store:open(data_dir .. "/" .. DB_FILENAME, SCHEMA, MIGRATIONS)
end

--- Close the database connection
function SessionStore:close()
	self.store:close()
end

--- Save one finished session and its Page Views
-- In one transaction, so a session is never stored without its Page Views: the
-- server ignores the Page Views of a session it already has, and a session
-- uploaded without them would never get them.
-- @param session table The session's columns, already decided by the tracker,
--   and `page_views`, an array of {start_xpoint, end_xpoint, shown_at,
--   duration_seconds}
-- @return boolean Success status
function SessionStore:saveSession(session)
	local saved = self.store:transaction(function(store)
		local inserted = store:exec(
			INSERT_SESSION,
			SqliteStore.binds(
				session.book_file,
				session.book_hash,
				session.book_title,
				session.book_author,
				session.start_time,
				session.end_time,
				session.duration_seconds,
				session.position_type,
				session.start_position,
				session.end_position,
				session.start_page,
				session.end_page,
				session.total_pages,
				session.device_id
			)
		)
		if not inserted then
			return false
		end

		local ids = store:query("SELECT last_insert_rowid()", nil, function(row)
			return row[1]
		end)
		local session_id = ids and ids[1]
		if not session_id then
			return false
		end

		for _, page_view in ipairs(session.page_views or {}) do
			local placed = store:exec(
				INSERT_PAGE_VIEW,
				SqliteStore.binds(
					session_id,
					page_view.start_xpoint,
					page_view.end_xpoint,
					page_view.shown_at,
					page_view.duration_seconds
				)
			)
			if not placed then
				return false
			end
		end

		return true
	end)

	if saved then
		-- The device can be switched off the moment a book is closed, which is
		-- one of the ends that gets here.
		self.store:checkpoint()
	end

	return saved
end

--- Read a book's sessions that have not reached the server
-- Each record carries the columns the upload sends and the id it is marked
-- synced by, not the whole row, and its Page Views as `page_views`. When the
-- Page Views cannot be read, no session is answered: one uploaded without them
-- would be marked synced and never get them.
-- @param book_file_hash string MD5 hash of the book file path
-- @return table Array of session records, oldest first
function SessionStore:getUnsyncedSessionsForBook(book_file_hash)
	if not book_file_hash then
		return {}
	end

	-- Keyed by number: SQLite answers an integer as an int64 cdata, and two of
	-- those holding the same id are different table keys.
	local page_views_by_session = {}
	local page_views = self.store:query(
		SELECT_UNSYNCED_PAGE_VIEWS_FOR_BOOK,
		SqliteStore.binds(book_file_hash),
		function(row)
			local session_id = tonumber(row[1])
			local list = page_views_by_session[session_id]
			if not list then
				list = {}
				page_views_by_session[session_id] = list
			end
			table.insert(list, {
				start_xpoint = row[2],
				end_xpoint = row[3],
				shown_at = row[4],
				duration_seconds = row[5],
			})
			return true
		end
	)
	if not page_views then
		return {}
	end

	local sessions = self.store:query(SELECT_UNSYNCED_FOR_BOOK, SqliteStore.binds(book_file_hash), function(row)
		return {
			id = row[1],
			start_time = row[2],
			end_time = row[3],
			position_type = row[4],
			start_position = row[5],
			end_position = row[6],
			start_page = row[7],
			end_page = row[8],
			device_id = row[9],
			page_views = page_views_by_session[tonumber(row[1])] or {},
		}
	end)

	return sessions or {}
end

--- Mark sessions as synced
-- @param session_ids table Array of session IDs the server has accepted
-- @return boolean Success status
function SessionStore:markSessionsSynced(session_ids)
	if not session_ids or #session_ids == 0 then
		return true
	end

	local sql = "UPDATE sessions SET synced = 1 WHERE id IN (" .. placeholders(#session_ids) .. ")"
	return self.store:exec(sql, session_ids)
end

--- Delete the Page Views of the given sessions
-- @param session_ids table Array of session IDs the server has accepted
-- @return boolean Success status
function SessionStore:deletePageViews(session_ids)
	if not session_ids or #session_ids == 0 then
		return true
	end

	local sql = "DELETE FROM page_views WHERE session_id IN (" .. placeholders(#session_ids) .. ")"
	return self.store:exec(sql, session_ids)
end

return SessionStore
