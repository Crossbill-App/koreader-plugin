--[[
SQLite Store for Crossbill Sync

The plugin's one database file, opened in WAL mode, plus the statements run
against it and the checkpointing close. `main.lua` opens it and hands it to the
three stores over it -- the session store, the digest cache and the highlight
snapshot store -- each of which asks `ensureSchema` for its own tables and is
otherwise left with its queries. Three files were three of everything for no
reason a reader could see: three connections, three write-ahead logs and three
files cluttering the settings directory.

Opening and the schema are two calls because of that sharing: the file is opened
once, and each store brings its own CREATE statements and its own migrations to
the connection it was given.

Nothing here raises. Every caller is reached from a KOReader event handler, and
a page turn that ends in an error is a page turn the reader loses, so a database
that would not open answers as an empty one and a statement that fails is logged
and reported instead of unwound. That is also why a store is asked, never
assumed: `isOpen` is the single guard the three stores used to write out one
method at a time.
]]

local Log = require("modules/log")
local SQ3 = require("lua-ljsqlite3/init")

local SqliteStore = {}
SqliteStore.__index = SqliteStore

--- Build a bind list that keeps its nils
-- A nullable column is written by binding nil, and `#` and `unpack` both stop
-- at the first nil in an array -- so a plain `{ a, nil, c }` would quietly bind
-- one value and leave the rest NULL. This counts the arguments as they were
-- passed, so every placeholder is filled with what the caller meant.
-- @param ... any The values to bind, in placeholder order
-- @return table The bind list
function SqliteStore.binds(...)
	return { n = select("#", ...), ... }
end

--- Count a bind list, honouring the nils SqliteStore.binds preserved
-- @param binds table|nil The bind list
-- @return number How many placeholders it fills
local function bindCount(binds)
	if not binds then
		return 0
	end
	return binds.n or #binds
end

--- Create the plugin's database
-- @return SqliteStore instance
function SqliteStore:new()
	local instance = setmetatable({}, SqliteStore)
	instance.log = Log.forModule("Database")
	instance.db = nil
	instance.db_path = nil
	instance._initialized = false
	return instance
end

--- Open the database file, creating it when it is not there yet
-- @param path string Where the database file lives
-- @return boolean Success status
function SqliteStore:open(path)
	if self._initialized then
		return true
	end

	self.db_path = path
	self.log.dbg("Opening database at", path)

	local success, err = pcall(function()
		self.db = SQ3.open(path)
		-- WAL mode, so a write does not block the read behind the reader's next
		-- page turn.
		self.db:exec("PRAGMA journal_mode=WAL;")
	end)

	if not success then
		self.log.err("Failed to open database:", err)
		self.db = nil
		return false
	end

	self._initialized = true
	self.log.dbg("Database open")
	return true
end

--- Give one store the tables it works over
-- Called once per store on the open database, so each brings its own CREATE
-- statements to the connection it shares with the others.
-- @param schema string The CREATE statements, run on every open
-- @param migrations table|nil SQL statements that bring an older database up to
--   the schema; each is expected to fail once it has been applied
-- @return boolean Success status
function SqliteStore:ensureSchema(schema, migrations)
	if not self:isOpen() then
		self.log.warn("Cannot create a schema - database not open")
		return false
	end

	local success, err = pcall(function()
		self.db:exec(schema)
	end)

	if not success then
		self.log.err("Failed to create the schema:", err)
		return false
	end

	-- The schema only creates what is not there yet, so a column added to it
	-- later never reaches a database that already has the table. Migrations are
	-- how such a column arrives, and each is guarded on its own: on a database
	-- that already has it the statement fails, and that is the ordinary case
	-- rather than a reason to refuse the whole schema.
	for _, migration in ipairs(migrations or {}) do
		local applied, migration_err = pcall(function()
			self.db:exec(migration)
		end)
		if not applied then
			self.log.dbg("Migration left alone (already applied?):", migration_err)
		end
	end

	return true
end

--- Check whether there is a database to talk to
-- @return boolean True when the database is open
function SqliteStore:isOpen()
	return self._initialized and self.db ~= nil
end

--- Close the database connection
function SqliteStore:close()
	if self.db then
		self.log.dbg("Closing database")
		local success, err = pcall(function()
			-- Checkpoint so the write-ahead log reaches the database file: this
			-- is usually the last thing to happen before the device is put away.
			self.db:exec("PRAGMA wal_checkpoint(TRUNCATE);")
			self.db:close()
		end)
		if not success then
			self.log.warn("Error closing database:", err)
		end
		self.db = nil
	end
	self._initialized = false
end

--- Flush the write-ahead log into the database file
-- Passive: it gives way to a reader rather than waiting for one, which is what
-- a call after every write wants.
function SqliteStore:checkpoint()
	if not self:isOpen() then
		return
	end

	local success, err = pcall(function()
		self.db:exec("PRAGMA wal_checkpoint(PASSIVE);")
	end)

	if not success then
		self.log.warn("Checkpoint failed:", err)
	end
end

--- Run one statement
-- @param sql string A single SQL statement, with ? placeholders
-- @param binds table|nil Values for the placeholders; build it with
--   SqliteStore.binds when any of them can be nil
-- @return boolean Success status
function SqliteStore:exec(sql, binds)
	if not self:isOpen() then
		self.log.warn("Cannot run a statement - database not open")
		return false
	end

	local stmt
	local success, err = pcall(function()
		stmt = self.db:prepare(sql)
		local count = bindCount(binds)
		if count > 0 then
			stmt:bind(unpack(binds, 1, count))
		end
		stmt:step()
	end)

	-- Closed outside the pcall so a statement that failed halfway still gives
	-- its handle back.
	if stmt then
		pcall(function()
			stmt:close()
		end)
	end

	if not success then
		self.log.err("Statement failed:", err, sql)
		return false
	end

	return true
end

--- Run a query and map its rows
-- @param sql string A single SELECT, with ? placeholders
-- @param binds table|nil Values for the placeholders; build it with
--   SqliteStore.binds when any of them can be nil
-- @param mapRow function Called with each row; what it returns is collected,
--   and a row it maps to nil is dropped
-- @return table|nil The mapped rows, nil when the query failed
function SqliteStore:query(sql, binds, mapRow)
	if not self:isOpen() then
		return nil
	end

	local mapped = {}
	local stmt
	local success, err = pcall(function()
		stmt = self.db:prepare(sql)
		local count = bindCount(binds)
		if count > 0 then
			stmt:bind(unpack(binds, 1, count))
		end
		for row in stmt:rows() do
			local value = mapRow(row)
			if value ~= nil then
				table.insert(mapped, value)
			end
		end
	end)

	if stmt then
		pcall(function()
			stmt:close()
		end)
	end

	if not success then
		self.log.err("Query failed:", err, sql)
		return nil
	end

	return mapped
end

--- Read one value: the first column of a query's first row
-- `query` could answer this, but only through a mapping function and a table
-- the caller then unwraps, which is three lines of ceremony around a COUNT.
-- @param sql string A single SELECT, with ? placeholders
-- @param binds table|nil Values for the placeholders; build it with
--   SqliteStore.binds when any of them can be nil
-- @return any|nil The value, nil when the query failed, returned no row, or the
--   column was NULL. A COUNT always answers with a row, so nil there is a
--   failure and callers read it that way.
function SqliteStore:scalar(sql, binds)
	if not self:isOpen() then
		return nil
	end

	local value
	local stmt
	local success, err = pcall(function()
		stmt = self.db:prepare(sql)
		local count = bindCount(binds)
		if count > 0 then
			stmt:bind(unpack(binds, 1, count))
		end
		local row = stmt:step()
		if row then
			value = row[1]
		end
	end)

	if stmt then
		pcall(function()
			stmt:close()
		end)
	end

	if not success then
		self.log.err("Query failed:", err, sql)
		return nil
	end

	return value
end

--- Run a series of statements as one transaction
-- @param fn function Called with this store; raising or returning false rolls
--   the transaction back. A statement the store merely reports as failed does
--   not: a caller that wants one to be fatal returns false on it, and one that
--   can live without it (a single bad row out of many) carries on.
-- @return boolean Success status
function SqliteStore:transaction(fn)
	if not self:isOpen() then
		self.log.warn("Cannot run a transaction - database not open")
		return false
	end

	local success, result = pcall(function()
		self.db:exec("BEGIN TRANSACTION;")
		return fn(self)
	end)

	if success and result ~= false then
		local committed, commit_err = pcall(function()
			self.db:exec("COMMIT;")
		end)
		if committed then
			return true
		end
		self.log.err("Failed to commit, rolling back:", commit_err)
	else
		self.log.err("Transaction failed, rolling back:", success and "a statement was refused" or result)
	end

	pcall(function()
		self.db:exec("ROLLBACK;")
	end)

	return false
end

return SqliteStore
