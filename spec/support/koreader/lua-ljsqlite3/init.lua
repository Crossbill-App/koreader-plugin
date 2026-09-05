--[[
Stub for the SQLite binding KOReader bundles as `lua-ljsqlite3/init`.

`modules/sqlite_store` holds a reference to it, and the three stores built on it
-- the session store, the digest cache and the highlight snapshot store -- reach
it that way, so requiring any of them, or main.lua, needs it to exist. None of
them touches it until the database is opened, which no spec does: only main.lua
opens it, and the modules above those stores take one as a dependency and specs
hand them an in-memory stand-in instead (`spec/support/fake_session_store.lua`,
`spec/support/fake_snapshot_store.lua`).

So this refuses loudly rather than pretending to be a database. Reaching the
error means a spec has started exercising code that really does talk to SQLite;
give it a real binding then, do not widen the stub.
]]

local SQ3 = {}

--- Open a database
-- @param path string Where the database lives
function SQ3.open(path)
	error("lua-ljsqlite3 stub: opening a database is not implemented, asked for: " .. tostring(path))
end

return SQ3
