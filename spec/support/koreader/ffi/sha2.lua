--[[
Stub for KOReader's `ffi/sha2`.

The real digests are LuaJIT FFI bindings, unavailable outside the reader. What
the plugin actually relies on is that a digest is a pure function of its input,
so these return readable, deterministic stand-ins. Specs can then assert on the
exact string that was hashed -- which is the part we own -- rather than on a
hex digest that only restates the algorithm.
]]

local sha2 = {}

--- Deterministic stand-in for an MD5 digest
-- @param input string The string to hash
-- @return string A marker wrapping the input verbatim
function sha2.md5(input)
	return "md5:" .. input
end

--- Deterministic stand-in for a SHA-256 digest
-- @param input string The string to hash
-- @return string A marker wrapping the input verbatim
function sha2.sha256(input)
	return "sha256:" .. input
end

return sha2
