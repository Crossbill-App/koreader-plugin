local lfs = require("lfs")
local LegacyDatabases = require("modules/legacy_databases")
local PluginIdentity = require("modules/plugin_identity")

describe("LegacyDatabases", function()
	local root

	--- A database that records the SQL it is asked to run
	-- The real one is SQLite, which the specs deliberately do not stand in for
	-- (see spec/support/koreader/lua-ljsqlite3), so what is checked here is the
	-- sequence of statements and the decisions taken on the counts they answer.
	-- @param opts table|nil `counts` maps a table name to the numbers its
	--   COUNT(*) answers in order, `raise_on` a pattern whose statement blows
	--   up, and `refuse_on` a pattern whose statement comes back as failed
	-- @return table The store stand-in
	local function fakeStore(opts)
		opts = opts or {}
		local counts = {}
		for name, values in pairs(opts.counts or {}) do
			counts[name] = { unpack(values) }
		end

		local store = { statements = {}, in_transaction = false }

		function store:isOpen()
			return opts.open ~= false
		end

		function store:record(sql)
			table.insert(self.statements, (sql:gsub("%s+", " "):gsub("^ ", ""):gsub(" $", "")))
			if opts.raise_on and sql:find(opts.raise_on) then
				error("the database gave up on: " .. sql)
			end
			return not (opts.refuse_on and sql:find(opts.refuse_on))
		end

		function store:exec(sql, binds)
			local ok = self:record(sql)
			if binds then
				table.insert(self.statements, "binds: " .. table.concat(binds, ",", 1, binds.n or #binds))
			end
			return ok
		end

		function store:migrate(statements)
			for _, sql in ipairs(statements or {}) do
				self:record(sql)
			end
		end

		function store:scalar(sql)
			self:record(sql)
			local name = sql:match("FROM%s+(%S+)")
			local answers = counts[name]
			assert(answers and #answers > 0, "the fake store has no count left for " .. tostring(name))
			return table.remove(answers, 1)
		end

		function store:transaction(fn)
			self:record("BEGIN TRANSACTION;")
			local ok, result = pcall(fn, self)
			self:record(ok and result ~= false and "COMMIT;" or "ROLLBACK;")
			if not ok then
				error(result, 0)
			end
			return result ~= false
		end

		return store
	end

	--- The path an old database of this plugin's would have
	-- @param suffix string The filename's tail, e.g. "_sessions.sqlite3"
	-- @return string The path
	local function legacyPath(suffix)
		return root .. "/" .. PluginIdentity.namespace .. suffix
	end

	--- Write an old database file, with the sidecars WAL would have left
	-- The bytes are not SQLite: nothing here opens them, and the file's
	-- existence is the whole of what the module reads from the filesystem.
	-- @param suffix string The filename's tail
	-- @return string The path written
	local function writeLegacy(suffix)
		for _, tail in ipairs({ "", "-wal", "-shm" }) do
			local file = assert(io.open(legacyPath(suffix) .. tail, "w"))
			file:write("not really a database")
			file:close()
		end
		return legacyPath(suffix)
	end

	--- Whether a path is a file that exists
	-- @param path string The path
	-- @return boolean True when it is
	local function exists(path)
		return lfs.attributes(path, "mode") == "file"
	end

	--- Every statement the store was asked to run, as one string
	-- @param store table The store stand-in
	-- @return string The statements, joined
	local function ranSql(store)
		return table.concat(store.statements, "\n")
	end

	--- Counts that let a sessions file of the given size copy cleanly
	-- @param rows number How many rows the old file holds
	-- @return table The count script
	local function sessionCounts(rows)
		return { ["main.sessions"] = { 0, rows }, ["legacy.sessions"] = { rows } }
	end

	before_each(function()
		root = os.tmpname()
		os.remove(root)
		assert(lfs.mkdir(root))
	end)

	after_each(function()
		if root and lfs.attributes(root, "mode") == "directory" then
			for entry in lfs.dir(root) do
				if entry ~= "." and entry ~= ".." then
					os.remove(root .. "/" .. entry)
				end
			end
			lfs.rmdir(root)
		end
	end)

	describe("with no old databases beside the new one", function()
		it("runs nothing at all", function()
			local store = fakeStore()

			LegacyDatabases.absorb(store, root)

			assert.are.same({}, store.statements)
		end)
	end)

	describe("with a sessions database left over", function()
		it("attaches it with the path bound rather than spliced in", function()
			local store = fakeStore({ counts = sessionCounts(3) })
			local path = writeLegacy("_sessions.sqlite3")

			LegacyDatabases.absorb(store, root)

			assert.are.equal("ATTACH DATABASE ? AS legacy", store.statements[1])
			assert.are.equal("binds: " .. path, store.statements[2])
		end)

		it("adds the author column before selecting it", function()
			local store = fakeStore({ counts = sessionCounts(3) })
			writeLegacy("_sessions.sqlite3")

			LegacyDatabases.absorb(store, root)

			local sql = ranSql(store)
			local altered = sql:find("ALTER TABLE legacy.sessions ADD COLUMN book_author TEXT", 1, true)
			local selected = sql:find("FROM legacy.sessions", 1, true)
			assert.is_truthy(altered)
			assert.is_true(altered < selected)
		end)

		it("copies the rows inside a transaction, without their ids", function()
			local store = fakeStore({ counts = sessionCounts(3) })
			writeLegacy("_sessions.sqlite3")

			LegacyDatabases.absorb(store, root)

			local sql = ranSql(store)
			local began = sql:find("BEGIN TRANSACTION;", 1, true)
			local copied = sql:find("INSERT INTO main.sessions", 1, true)
			local committed = sql:find("COMMIT;", 1, true)
			assert.is_true(began < copied and copied < committed)
			assert.is_nil(sql:find("INSERT INTO main.sessions ( id", 1, true))
		end)

		it("counts the rows on both sides", function()
			local store = fakeStore({ counts = sessionCounts(3) })
			writeLegacy("_sessions.sqlite3")

			LegacyDatabases.absorb(store, root)

			local sql = ranSql(store)
			assert.is_truthy(sql:find("SELECT COUNT(*) FROM legacy.sessions", 1, true))
			assert.is_truthy(sql:find("SELECT COUNT(*) FROM main.sessions", 1, true))
		end)

		it("detaches the old file afterwards", function()
			local store = fakeStore({ counts = sessionCounts(3) })
			writeLegacy("_sessions.sqlite3")

			LegacyDatabases.absorb(store, root)

			assert.are.equal("DETACH DATABASE legacy", store.statements[#store.statements])
		end)

		it("removes the file and the sidecars WAL left", function()
			local store = fakeStore({ counts = sessionCounts(3) })
			local path = writeLegacy("_sessions.sqlite3")

			LegacyDatabases.absorb(store, root)

			assert.is_false(exists(path))
			assert.is_false(exists(path .. "-wal"))
			assert.is_false(exists(path .. "-shm"))
		end)

		it("finds nothing to do the second time round", function()
			local store = fakeStore({ counts = sessionCounts(3) })
			writeLegacy("_sessions.sqlite3")
			LegacyDatabases.absorb(store, root)

			local second = fakeStore()
			LegacyDatabases.absorb(second, root)

			assert.are.same({}, second.statements)
		end)
	end)

	describe("when the copy does not add up", function()
		it("leaves the file in place when rows went missing", function()
			local store = fakeStore({ counts = { ["main.sessions"] = { 0, 2 }, ["legacy.sessions"] = { 3 } } })
			local path = writeLegacy("_sessions.sqlite3")

			LegacyDatabases.absorb(store, root)

			assert.is_true(exists(path))
			assert.are.equal("DETACH DATABASE legacy", store.statements[#store.statements])
		end)

		it("leaves the file in place when the statement was refused", function()
			local store = fakeStore({
				counts = { ["main.sessions"] = { 0 }, ["legacy.sessions"] = { 3 } },
				refuse_on = "INSERT INTO main.sessions",
			})
			local path = writeLegacy("_sessions.sqlite3")

			LegacyDatabases.absorb(store, root)

			assert.is_true(exists(path))
			assert.is_truthy(ranSql(store):find("ROLLBACK;", 1, true))
		end)

		it("leaves the file in place and still detaches when the database blows up", function()
			local store = fakeStore({
				counts = { ["main.sessions"] = { 0 }, ["legacy.sessions"] = { 3 } },
				raise_on = "INSERT INTO main.sessions",
			})
			local path = writeLegacy("_sessions.sqlite3")

			LegacyDatabases.absorb(store, root)

			assert.is_true(exists(path))
			assert.is_true(exists(path .. "-wal"))
			assert.are.equal("DETACH DATABASE legacy", store.statements[#store.statements])
		end)

		it("carries on with the next file", function()
			local store = fakeStore({
				counts = { ["main.sessions"] = { 0 }, ["legacy.sessions"] = { 3 } },
				raise_on = "INSERT INTO main.sessions",
			})
			writeLegacy("_sessions.sqlite3")
			local digests = writeLegacy("_digests.sqlite3")

			LegacyDatabases.absorb(store, root)

			assert.is_false(exists(digests))
		end)
	end)

	describe("with a highlight ledger left over", function()
		it("copies both tables so a row already here wins", function()
			local store = fakeStore({
				counts = {
					["main.highlight_snapshot"] = { 1, 4 },
					["legacy.highlight_snapshot"] = { 4 },
					["main.highlight_snapshot_book"] = { 1, 2 },
					["legacy.highlight_snapshot_book"] = { 2 },
				},
			})
			local path = writeLegacy("_highlights.sqlite3")

			LegacyDatabases.absorb(store, root)

			local sql = ranSql(store)
			assert.is_truthy(sql:find("ALTER TABLE legacy.highlight_snapshot_book ADD COLUMN book_file_hash", 1, true))
			assert.is_truthy(sql:find("INSERT OR IGNORE INTO main.highlight_snapshot (", 1, true))
			assert.is_truthy(sql:find("INSERT OR IGNORE INTO main.highlight_snapshot_book (", 1, true))
			assert.is_false(exists(path))
		end)

		it("accepts fewer rows than the old file held", function()
			-- Every row the old file has is already here, so OR IGNORE adds
			-- none of them and the ledger is still whole.
			local store = fakeStore({
				counts = {
					["main.highlight_snapshot"] = { 4, 4 },
					["legacy.highlight_snapshot"] = { 4 },
					["main.highlight_snapshot_book"] = { 2, 2 },
					["legacy.highlight_snapshot_book"] = { 2 },
				},
			})
			local path = writeLegacy("_highlights.sqlite3")

			LegacyDatabases.absorb(store, root)

			assert.is_false(exists(path))
		end)

		it("refuses more rows than the old file held", function()
			local store = fakeStore({
				counts = {
					["main.highlight_snapshot"] = { 0, 9 },
					["legacy.highlight_snapshot"] = { 4 },
					["main.highlight_snapshot_book"] = { 0, 2 },
					["legacy.highlight_snapshot_book"] = { 2 },
				},
			})
			local path = writeLegacy("_highlights.sqlite3")

			LegacyDatabases.absorb(store, root)

			assert.is_true(exists(path))
		end)
	end)

	describe("with a digest cache left over", function()
		it("deletes it without reading a row", function()
			local store = fakeStore()
			local path = writeLegacy("_digests.sqlite3")

			LegacyDatabases.absorb(store, root)

			assert.are.same({}, store.statements)
			assert.is_false(exists(path))
			assert.is_false(exists(path .. "-wal"))
		end)
	end)

	describe("with no database to copy into", function()
		it("leaves the old files alone", function()
			local store = fakeStore({ open = false })
			local path = writeLegacy("_sessions.sqlite3")

			LegacyDatabases.absorb(store, root)

			assert.are.same({}, store.statements)
			assert.is_true(exists(path))
		end)
	end)
end)
