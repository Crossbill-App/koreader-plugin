--[[
End-to-end check of the one-database migration, against real SQLite.

`modules/legacy_databases` carries a reader's reading history and highlight
ledger out of the three databases the plugin used to keep and then deletes
those files. Busted cannot exercise that: the specs deliberately have no SQLite
binding (see spec/support/koreader/lua-ljsqlite3), so `spec/legacy_databases_spec`
checks the statements and the decisions and not what SQLite makes of them. What
is left over is the part that can lose someone's history, so it is checked here
instead, on real files with real rows.

Run it with LuaJIT and a directory holding KOReader's SQLite binding:

    luajit scripts/verify_database_migration.lua <dir-with-lua-ljsqlite3>

That directory goes on `package.path` ahead of everything else, so the real
binding shadows the refusing stub the specs use. Both shapes of old database
are built and migrated: the oldest one the plugin ever wrote, which has a
`sync_attempts` column since dropped and lacks `book_author` and
`book_file_hash`, and the last one before the three files became one.
]]

local binding_dir = arg[1]

if not binding_dir then
	io.stderr:write("usage: luajit scripts/verify_database_migration.lua <dir-with-lua-ljsqlite3>\n")
	os.exit(2)
end

local repo_root = (arg[0] or ""):match("^(.*)/scripts/[^/]+$") or "."

-- The binding directory first: `spec/support/koreader` holds a `lua-ljsqlite3`
-- that refuses to open anything, which is right for busted and useless here.
package.path = table.concat({
	binding_dir .. "/?.lua",
	binding_dir .. "/?/init.lua",
	repo_root .. "/crossbill.koplugin/?.lua",
	repo_root .. "/spec/support/koreader/?.lua",
	package.path,
}, ";")

-- The real LuaFileSystem, which `libs/libkoreader-lfs` hands over.
package.cpath = (os.getenv("HOME") or "") .. "/.luarocks/lib/lua/5.1/?.so;" .. package.cpath

local lfs = require("lfs")
local SQ3 = require("lua-ljsqlite3/init")
local PluginIdentity = require("modules/plugin_identity")
local SqliteStore = require("modules/sqlite_store")
local SessionStore = require("modules/session_store")
local DigestCache = require("modules/digest_cache")
local HighlightSnapshotStore = require("modules/highlight_snapshot_store")
local LegacyDatabases = require("modules/legacy_databases")

-- The schemas the oldest databases on a reader's device were written with.
-- `sessions` has no `book_author` and a `sync_attempts` the current schema
-- dropped; `highlight_snapshot_book` has no `book_file_hash`.
local OLDEST = {
	sessions = [[
CREATE TABLE IF NOT EXISTS sessions (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    book_file TEXT NOT NULL,
    book_hash TEXT NOT NULL,
    book_title TEXT,
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
    sync_attempts INTEGER DEFAULT 0,
    created_at INTEGER DEFAULT (strftime('%s', 'now')),
    device_id TEXT
);
]],
	highlights = [[
CREATE TABLE IF NOT EXISTS highlight_snapshot (
    client_book_id TEXT NOT NULL,
    server_id      INTEGER NOT NULL,
    text_hash      TEXT NOT NULL,
    PRIMARY KEY (client_book_id, server_id)
);
CREATE TABLE IF NOT EXISTS highlight_snapshot_book (
    client_book_id TEXT PRIMARY KEY,
    updated_at     INTEGER NOT NULL,
    item_count     INTEGER NOT NULL
);
]],
}

-- The schemas the last three-file version wrote, which are the ones the single
-- database now creates.
local CURRENT = {
	sessions = [[
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
]],
	highlights = [[
CREATE TABLE IF NOT EXISTS highlight_snapshot (
    client_book_id TEXT NOT NULL,
    server_id      INTEGER NOT NULL,
    text_hash      TEXT NOT NULL,
    PRIMARY KEY (client_book_id, server_id)
);
CREATE TABLE IF NOT EXISTS highlight_snapshot_book (
    client_book_id TEXT PRIMARY KEY,
    updated_at     INTEGER NOT NULL,
    item_count     INTEGER NOT NULL,
    book_file_hash TEXT
);
]],
}

local DIGESTS = [[
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
CREATE TABLE IF NOT EXISTS digest_fetch_meta (
    client_book_id TEXT PRIMARY KEY,
    fetched_at     INTEGER NOT NULL,
    item_count     INTEGER NOT NULL
);
]]

local failures = 0
local checks = 0

--- Report one assertion
-- @param ok boolean|nil Whether it held
-- @param description string What was being asserted
-- @param detail any|nil What was seen instead
local function check(ok, description, detail)
	checks = checks + 1
	if ok then
		print("  PASS  " .. description)
	else
		failures = failures + 1
		print("  FAIL  " .. description .. (detail ~= nil and ("  (got: " .. tostring(detail) .. ")") or ""))
	end
end

--- Every row of a query, as plain Lua arrays
-- The binding hands NULL back as nil, so the column count is passed in rather
-- than taken from the row.
-- @param db table An open connection
-- @param sql string The query
-- @param columns number How many columns it selects
-- @return table Array of rows
local function fetchAll(db, sql, columns)
	local stmt = db:prepare(sql)
	local rows = {}

	while true do
		local row = stmt:step()
		if not row then
			break
		end
		local copy = {}
		for i = 1, columns do
			copy[i] = row[i]
		end
		table.insert(rows, copy)
	end

	stmt:close()
	return rows
end

--- The single number a COUNT answers with
-- @param db table An open connection
-- @param sql string The query
-- @return number The count
local function countOf(db, sql)
	return tonumber(fetchAll(db, sql, 1)[1][1])
end

--- Open a database in WAL mode and run a schema on it
-- Left open by the caller's design: WAL keeps its `-wal` and `-shm` beside the
-- file while a connection holds it, which is the state the migration has to
-- clean up after.
-- @param path string Where to write it
-- @param schema string The CREATE statements
-- @return table The open connection
local function createLegacy(path, schema)
	local db = SQ3.open(path)
	db:exec("PRAGMA journal_mode=WAL;")
	db:exec(schema)
	return db
end

--- Insert one old reading session
-- @param db table The old sessions database
-- @param oldest boolean Whether it has the oldest schema
-- @param id number The id the old file gave it, which must not survive
-- @param title string The book's title
-- @param author string|nil The author, where the schema has the column
local function insertSession(db, oldest, id, title, author)
	if oldest then
		db:exec(
			string.format(
				"INSERT INTO sessions (id, book_file, book_hash, book_title, start_time, end_time, "
					.. "duration_seconds, position_type, start_position, end_position, start_page, end_page, "
					.. "total_pages, synced, sync_attempts, created_at, device_id) VALUES "
					.. "(%d, '/books/%s.epub', 'hash-%d', '%s', 100, 200, 100, 'page', '1', '9', 1, 9, 300, 0, 2, 50, 'dev')",
				id,
				title,
				id,
				title
			)
		)
		return
	end

	db:exec(
		string.format(
			"INSERT INTO sessions (id, book_file, book_hash, book_title, book_author, start_time, end_time, "
				.. "duration_seconds, position_type, start_position, end_position, start_page, end_page, "
				.. "total_pages, synced, created_at, device_id) VALUES "
				.. "(%d, '/books/%s.epub', 'hash-%d', '%s', %s, 100, 200, 100, 'page', '1', '9', 1, 9, 300, 0, 50, 'dev')",
			id,
			title,
			id,
			title,
			author and ("'" .. author .. "'") or "NULL"
		)
	)
end

--- Everything left in a directory, sorted
-- @param dir string The directory
-- @return table Array of names
local function entriesOf(dir)
	local names = {}
	for entry in lfs.dir(dir) do
		if entry ~= "." and entry ~= ".." then
			table.insert(names, entry)
		end
	end
	table.sort(names)
	return names
end

--- Delete a directory and everything in it
-- @param dir string The directory
local function purge(dir)
	for _, entry in ipairs(entriesOf(dir)) do
		os.remove(dir .. "/" .. entry)
	end
	lfs.rmdir(dir)
end

--- Build a settings directory holding the three old databases
-- @param oldest boolean Whether to write the oldest schemas
-- @return string, table The directory, and the connections holding it open
local function buildLegacyDirectory(oldest)
	local dir = os.tmpname()
	os.remove(dir)
	assert(lfs.mkdir(dir))

	local schemas = oldest and OLDEST or CURRENT
	local prefix = dir .. "/" .. PluginIdentity.namespace

	local sessions = createLegacy(prefix .. "_sessions.sqlite3", schemas.sessions)
	-- The middle one has no author in either shape: the oldest schema has
	-- nowhere to put one, and the current one is allowed to leave it NULL.
	insertSession(sessions, oldest, 1, "Kalevala", "Lonnrot")
	insertSession(sessions, oldest, 2, "Seitseman", nil)
	insertSession(sessions, oldest, 3, "Sinuhe", "Waltari")

	local highlights = createLegacy(prefix .. "_highlights.sqlite3", schemas.highlights)
	highlights:exec("INSERT INTO highlight_snapshot VALUES ('book-a', 1, 'old-hash-1');")
	highlights:exec("INSERT INTO highlight_snapshot VALUES ('book-a', 2, 'old-hash-2');")
	highlights:exec("INSERT INTO highlight_snapshot VALUES ('book-b', 1, 'old-hash-3');")
	if oldest then
		highlights:exec("INSERT INTO highlight_snapshot_book VALUES ('book-a', 500, 2);")
		highlights:exec("INSERT INTO highlight_snapshot_book VALUES ('book-b', 500, 1);")
	else
		highlights:exec("INSERT INTO highlight_snapshot_book VALUES ('book-a', 500, 2, 'file-a');")
		highlights:exec("INSERT INTO highlight_snapshot_book VALUES ('book-b', 500, 1, 'file-b');")
	end

	local digests = createLegacy(prefix .. "_digests.sqlite3", DIGESTS)
	digests:exec("INSERT INTO digest VALUES ('book-a', 1, 'One', NULL, 's', '[]', '[]', NULL, 500);")
	digests:exec("INSERT INTO digest_fetch_meta VALUES ('book-a', 500, 1);")

	return dir, { sessions, highlights, digests }
end

--- Open the plugin's database and prepare its tables, the way main.lua:init does
-- @param dir string The settings directory
-- @return table The open store
local function openPluginDatabase(dir)
	local store = SqliteStore:new()
	assert(store:open(dir .. "/" .. PluginIdentity.database_filename), "the new database would not open")
	assert(SessionStore:new(store):prepare(), "the sessions table would not prepare")
	assert(DigestCache:new(store):prepare(), "the digest tables would not prepare")
	assert(HighlightSnapshotStore:new(store):prepare(), "the ledger tables would not prepare")
	return store
end

--- Run the whole migration over one shape of old database and check the result
-- @param oldest boolean Whether the old files use the oldest schemas
local function verify(oldest)
	print((oldest and "Oldest" or "Current") .. " schemas:")

	local dir, legacy_connections = buildLegacyDirectory(oldest)
	local prefix = dir .. "/" .. PluginIdentity.namespace
	local store = openPluginDatabase(dir)
	local db = store.db

	-- A session and a ledger row already in the new database, so that the old
	-- file's ids collide and the ledger has something of its own to defend.
	db:exec(
		"INSERT INTO sessions (book_file, book_hash, book_title, book_author, start_time, end_time, "
			.. "duration_seconds, position_type, start_position, end_position, start_page, end_page, "
			.. "total_pages, synced, device_id) VALUES "
			.. "('/books/new.epub', 'hash-new', 'Uusi', 'Uusinen', 900, 1000, 100, 'page', '1', '2', 1, 2, 10, 0, 'dev');"
	)
	db:exec("INSERT INTO highlight_snapshot VALUES ('book-a', 1, 'new-hash-1');")

	LegacyDatabases.absorb(store, dir)

	local sessions = fetchAll(db, "SELECT id, book_title, book_author FROM sessions ORDER BY id", 3)
	check(#sessions == 4, "every old session arrived beside the one already here", #sessions)

	local ids, distinct = {}, true
	for _, row in ipairs(sessions) do
		local id = tonumber(row[1])
		if ids[id] then
			distinct = false
		end
		ids[id] = true
	end
	check(
		distinct and ids[1] and ids[4],
		"the new table gave the copied rows its own ids",
		table.concat({
			tostring(sessions[1][1]),
			tostring(sessions[2][1]),
			tostring(sessions[3][1]),
			tostring(sessions[4][1]),
		}, ",")
	)

	local nullable = fetchAll(db, "SELECT book_title FROM sessions WHERE book_author IS NULL ORDER BY book_title", 1)
	local expected_nulls = oldest and 3 or 1
	check(#nullable == expected_nulls, "a session the old file had no author for is NULL, not missing", #nullable)

	local titles = fetchAll(db, "SELECT book_title FROM sessions WHERE book_hash = 'hash-3'", 1)
	check(titles[1] and titles[1][1] == "Sinuhe", "the copied columns kept their values", titles[1] and titles[1][1])

	check(countOf(db, "SELECT COUNT(*) FROM highlight_snapshot") == 3, "the ledger's rows arrived")
	check(
		countOf(db, "SELECT COUNT(*) FROM highlight_snapshot WHERE text_hash = 'new-hash-1'") == 1,
		"a ledger row already here won over the old file's"
	)
	check(countOf(db, "SELECT COUNT(*) FROM highlight_snapshot_book") == 2, "the ledger's books arrived")

	local stamped =
		fetchAll(db, "SELECT book_file_hash FROM highlight_snapshot_book WHERE client_book_id = 'book-a'", 1)
	-- Nil rather than an `and`/`or`, which cannot carry a nil through.
	local expected_stamp
	if not oldest then
		expected_stamp = "file-a"
	end
	check(
		stamped[1] and stamped[1][1] == expected_stamp,
		"the file hash came over where the old file had one",
		tostring(stamped[1] and stamped[1][1])
	)

	check(countOf(db, "SELECT COUNT(*) FROM digest") == 0, "the digest cache was not copied")

	local left = entriesOf(dir)
	local unexpected = {}
	for _, name in ipairs(left) do
		if not name:find("^" .. PluginIdentity.namespace .. "%.sqlite3") then
			table.insert(unexpected, name)
		end
	end
	check(#unexpected == 0, "every old file and sidecar is gone", table.concat(unexpected, ", "))
	check(
		lfs.attributes(prefix .. "_digests.sqlite3", "mode") == nil,
		"the digest database was deleted rather than kept"
	)

	local before = {
		sessions = countOf(db, "SELECT COUNT(*) FROM sessions"),
		snapshot = countOf(db, "SELECT COUNT(*) FROM highlight_snapshot"),
		books = countOf(db, "SELECT COUNT(*) FROM highlight_snapshot_book"),
	}

	LegacyDatabases.absorb(store, dir)

	check(
		countOf(db, "SELECT COUNT(*) FROM sessions") == before.sessions
			and countOf(db, "SELECT COUNT(*) FROM highlight_snapshot") == before.snapshot
			and countOf(db, "SELECT COUNT(*) FROM highlight_snapshot_book") == before.books,
		"a second open finds nothing to do"
	)

	store:close()
	for _, connection in ipairs(legacy_connections) do
		pcall(function()
			connection:close()
		end)
	end
	purge(dir)
end

print("Verifying the one-database migration against real SQLite")
verify(true)
verify(false)

print(string.format("\n%d checks, %d failed", checks, failures))
os.exit(failures == 0 and 0 or 1)
