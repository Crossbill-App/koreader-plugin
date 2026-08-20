--[[
Stub for KOReader's `ffi/sha2`.

The real `md5` is a LuaJIT FFI binding, unavailable outside the reader. What the
plugin actually relies on is that the digest is a pure function of its input, so
this returns a readable, deterministic stand-in. Specs can then assert on the
exact string that was hashed -- which is the part we own -- rather than on a
hex digest that only restates MD5.
]]

local sha2 = {}

--- Deterministic stand-in for an MD5 digest
-- @param input string The string to hash
-- @return string A marker wrapping the input verbatim
function sha2.md5(input)
	return "md5:" .. input
end

return sha2
