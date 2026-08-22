--[[
Stub for the SQLite binding KOReader bundles as `lua-ljsqlite3/init`.

Three of the plugin's modules hold a reference to it -- the digest cache, the
session tracker and the highlight snapshot store -- so requiring any of them, or
main.lua, needs it to exist. None of them touches it until `init` opens a
database, which no spec does: the specs that cover those modules drive them
through their own fakes instead.

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
