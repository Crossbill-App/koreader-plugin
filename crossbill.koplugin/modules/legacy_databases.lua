--[[
Legacy Databases for Crossbill Sync

The plugin kept its rows in three SQLite files -- `<namespace>_sessions`,
`<namespace>_digests` and `<namespace>_highlights` -- before they became one
`<namespace>.sqlite3`. A reader who updates has all three sitting next to the
new, empty one, holding their reading history and the highlight ledger that
tells a highlight deleted on the device from one deleted on the server. This
carries those rows across on the first open after the update and then removes
the old files.

Sessions arrive without their ids. Nothing outside a single sync run refers to
a session id -- it is read from the store and handed straight back to mark the
row synced -- and reusing the old ones could collide with rows the new database
has already written, so the new table assigns its own. The ledger's rows come
over with `INSERT OR IGNORE`, because there the key means something: a book the
new database has already recorded knows more than the old file does, and wins.
Digests are not copied at all. They are a cache of what the server will say
again, refilled by the next chapter the reader opens, and copying them would be
work in aid of nothing.

The old file is deleted rather than renamed, so that nothing is left behind on
the device -- which is also why the copy is counted before it is trusted: the
rows are only removed once a committed transaction has been shown to have put
the same number of them in the new database. Anything short of that leaves the
file exactly where it was, and the next open tries again. The file's absence is
the only marker that the work is done, so a second run finds nothing to do.

Nothing here raises. It is reached from `main.lua:init`, which KOReader calls
while a book is being opened, and a reader whose book will not open because of
a database they never knew they had is worse off than one whose old sessions
are still waiting in the old file.
]]

local lfs = require("libs/libkoreader-lfs")
local Log = require("modules/log")
local PluginIdentity = require("modules/plugin_identity")
local SqliteStore = require("modules/sqlite_store")

local log = Log.forModule("LegacyDatabases")

local LegacyDatabases = {}

-- WAL leaves these next to the database, and a stale write-ahead log beside a
-- deleted database is both confusing and, if the file were ever recreated,
-- wrong.
local SIDECARS = { "-wal", "-shm" }

-- Each old file: what it is called, the columns its oldest version is missing,
-- and how its tables move over. `alters` run against the attached file before
-- anything selects from it, so that a SELECT never names a column that a
-- database written by an older plugin does not have; each is expected to fail
-- on a file that already has the column, exactly as the stores' own migrations
-- do. A file with no `copies` is dropped unread.
local LEGACY_FILES = {
	{
		suffix = "_sessions.sqlite3",
		alters = { "ALTER TABLE legacy.sessions ADD COLUMN book_author TEXT" },
		copies = {
			{
				-- Named columns rather than `SELECT *`: the id is deliberately
				-- left behind, the oldest files carry a `sync_attempts` the
				-- current schema dropped, and the column order differs between
				-- the two.
				table = "sessions",
				statement = [[
INSERT INTO main.sessions (
    book_file, book_hash, book_title, book_author,
    start_time, end_time, duration_seconds,
    position_type, start_position, end_position,
    start_page, end_page, total_pages,
    synced, created_at, device_id
)
SELECT book_file, book_hash, book_title, book_author,
       start_time, end_time, duration_seconds,
       position_type, start_position, end_position,
       start_page, end_page, total_pages,
       synced, created_at, device_id
FROM legacy.sessions
]],
				-- Every row is new, so every row must land.
				exact = true,
			},
		},
	},
	{
		suffix = "_highlights.sqlite3",
		alters = { "ALTER TABLE legacy.highlight_snapshot_book ADD COLUMN book_file_hash TEXT" },
		copies = {
			{
				table = "highlight_snapshot",
				statement = [[
INSERT OR IGNORE INTO main.highlight_snapshot (
    client_book_id, server_id, text_hash
)
SELECT client_book_id, server_id, text_hash
FROM legacy.highlight_snapshot
]],
			},
			{
				table = "highlight_snapshot_book",
				statement = [[
INSERT OR IGNORE INTO main.highlight_snapshot_book (
    client_book_id, updated_at, item_count, book_file_hash
)
SELECT client_book_id, updated_at, item_count, book_file_hash
FROM legacy.highlight_snapshot_book
]],
			},
		},
	},
	{
		-- A cache; see the header.
		suffix = "_digests.sqlite3",
	},
}

--- Whether a path is a file that exists
-- @param path string The path
-- @return boolean True when it is
local function isFile(path)
	return lfs.attributes(path, "mode") == "file"
end

--- Count the rows of one table
-- @param store SqliteStore The open database
-- @param table_name string The table, qualified with `main` or `legacy`
-- @return number|nil The count, nil when the query failed
local function countRows(store, table_name)
	return tonumber(store:scalar("SELECT COUNT(*) FROM " .. table_name))
end

--- Move one attached file's tables into the plugin's database
-- Raises rather than returns on a database that will not answer, so that the
-- caller's DETACH happens on the way out; a copy that simply did not add up
-- comes back as false.
-- @param store SqliteStore The open database, with the old file attached
-- @param copies table The table copies to run
-- @return boolean True when every table arrived
local function copyTables(store, copies)
	local before = {}
	local expected = {}

	for _, copy in ipairs(copies) do
		before[copy.table] = countRows(store, "main." .. copy.table)
		expected[copy.table] = countRows(store, "legacy." .. copy.table)

		if not before[copy.table] or not expected[copy.table] then
			log.err("Could not count", copy.table, "before copying")
			return false
		end
	end

	local copied = store:transaction(function(db)
		for _, copy in ipairs(copies) do
			if not db:exec(copy.statement) then
				return false
			end
		end
		return true
	end)

	if not copied then
		log.err("The copy was refused and rolled back")
		return false
	end

	for _, copy in ipairs(copies) do
		local after = countRows(store, "main." .. copy.table)

		if not after then
			log.err("Could not count", copy.table, "after copying")
			return false
		end

		local arrived = after - before[copy.table]
		-- An exact table adds every old row; one copied with OR IGNORE may add
		-- fewer, because a row the new database already had kept its own.
		-- Either way, more rows than the old file held means this did not do
		-- what it says it does.
		if arrived > expected[copy.table] or (copy.exact and arrived < expected[copy.table]) then
			log.err("Copied", arrived, "rows into", copy.table, "but the old file held", expected[copy.table])
			return false
		end

		log.info("Carried over", arrived, "rows into", copy.table)
	end

	return true
end

--- Attach one old file, copy what it holds, and detach it again
-- @param store SqliteStore The open database
-- @param path string The old file
-- @param copies table The table copies to run
-- @param alters table|nil Guarded ALTERs to bring the old file up to the
--   columns the copies name
-- @return boolean True when the file may be removed
local function absorbFile(store, path, copies, alters)
	-- Bound rather than spliced in: a settings directory can hold a quote as
	-- easily as any other character.
	if not store:exec("ATTACH DATABASE ? AS legacy", SqliteStore.binds(path)) then
		log.err("Could not attach", path)
		return false
	end

	local ok, copied = pcall(function()
		for _, alter in ipairs(alters or {}) do
			-- Expected to fail on anything but the oldest files, and reported
			-- by the store either way.
			store:exec(alter)
		end
		return copyTables(store, copies)
	end)

	if not store:exec("DETACH DATABASE legacy") then
		log.warn("Could not detach", path)
	end

	if not ok then
		log.err("Copying from", path, "failed:", copied)
		return false
	end

	return copied
end

--- Delete an old database file and whatever WAL left beside it
-- @param path string The old file
local function removeFile(path)
	local removed, err = os.remove(path)

	if not removed then
		log.warn("Could not remove", path, tostring(err))
		return
	end

	for _, sidecar in ipairs(SIDECARS) do
		if isFile(path .. sidecar) then
			os.remove(path .. sidecar)
		end
	end

	log.info("Removed", path)
end

--- Carry the rows of the old three-file database into this one
-- Safe to call on every open: once an old file is gone there is nothing left
-- to do, and a file that could not be copied is tried again next time.
-- @param store SqliteStore The plugin's database, open and with its tables made
-- @param data_dir string The settings directory the old files would be in
function LegacyDatabases.absorb(store, data_dir)
	if not store or not store:isOpen() or not data_dir then
		return
	end

	for _, legacy in ipairs(LEGACY_FILES) do
		local path = data_dir .. "/" .. PluginIdentity.namespace .. legacy.suffix

		-- One file's failure is not the next one's: each is its own attach,
		-- its own transaction and its own decision to delete.
		local ok, err = pcall(function()
			if not isFile(path) then
				return
			end

			log.info("Found an old database at", path)

			if not legacy.copies or absorbFile(store, path, legacy.copies, legacy.alters) then
				removeFile(path)
			end
		end)

		if not ok then
			log.err("Absorbing", path, "failed:", err)
		end
	end
end

return LegacyDatabases
