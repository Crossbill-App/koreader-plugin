--[[
Release Signature Verification for Crossbill Sync

Answers one question: was this archive signed by a key the plugin already
carries? Everything the installer does after that answer depends on it, and
nothing else in the plugin depends on this module.

The only FFI in the plugin lives here, deliberately. KOReader links LibreSSL,
whose libcrypto exports Ed25519 directly, so verification is one call rather
than a hash-then-verify dance. Ed25519 signs the message itself and hashes it
internally, so there is no digest step to get wrong.

Every failure answers false, including every way of being unable to answer at
all: a KOReader too old to ship LibreSSL, a library that will not load, a
signature of the wrong length. `isAvailable` tells those apart from a signature
that simply did not match, which is worth saying differently to a reader.
]]

local logger = require("logger")

local Signature = {}

-- What Ed25519 fixes: 64 bytes of signature, 32 bytes of public key
Signature.SIGNATURE_BYTES = 64
Signature.KEY_BYTES = 32

-- Resolved once, on the first call that needs it. nil means not tried yet,
-- false means tried and unavailable.
local libcrypto = nil

--- Load libcrypto, or record that it cannot be loaded
-- Both candidates are offered to `ffi.loadlib`: KOReader pins the LibreSSL
-- soname today, and the unversioned name keeps this working across a bump
-- rather than failing on a number that moved.
-- @return table|nil The library, nil when it is not available here
local function crypto()
	if libcrypto ~= nil then
		return libcrypto or nil
	end

	local ok, lib = pcall(function()
		local ffi = require("ffi")
		-- Added by koreader-base; requiring it is harmless if it already ran.
		if not ffi.loadlib then
			require("ffi/loadlib")
		end
		ffi.cdef([[
int ED25519_verify(const unsigned char *message, size_t message_len,
                   const unsigned char *signature,
                   const unsigned char *public_key);
]])
		local loaded = ffi.loadlib("crypto", "57", "crypto", nil)
		-- Touch the symbol now: a library without it fails here, where it can
		-- be reported, rather than at the first verification. The value is
		-- discarded; resolving it is the whole point.
		assert(loaded.ED25519_verify)
		return loaded
	end)

	if not ok then
		logger.warn("Crossbill: Ed25519 verification unavailable:", tostring(lib))
		libcrypto = false
		return nil
	end

	libcrypto = lib
	return libcrypto
end

--- The bytes a hex string stands for, when it is one of the right length
-- @param hex any The hex string
-- @param bytes number How many bytes it must describe
-- @return string|nil The bytes, nil when the string is not that
local function fromHex(hex, bytes)
	if type(hex) ~= "string" or #hex ~= bytes * 2 or hex:find("[^0-9a-fA-F]") then
		return nil
	end

	return (hex:gsub("..", function(pair)
		return string.char(tonumber(pair, 16))
	end))
end

--- Whether this device can verify a signature at all
-- Distinguishes "cannot check" from "checked and it did not match", which are
-- the same refusal but not the same thing to say to a reader.
-- @return boolean True when verification is possible here
function Signature.isAvailable()
	return crypto() ~= nil
end

--- Whether the data carries a signature from one of the trusted keys
-- @param data string The bytes that were signed
-- @param signature string The detached signature, 64 bytes
-- @param trusted_keys table The public keys, as hex strings
-- @return boolean True only when a trusted key verifies the signature
function Signature.verify(data, signature, trusted_keys)
	if type(data) ~= "string" or type(signature) ~= "string" then
		return false
	end

	if #signature ~= Signature.SIGNATURE_BYTES then
		logger.warn("Crossbill: signature is", #signature, "bytes, expected", Signature.SIGNATURE_BYTES)
		return false
	end

	-- Decode before loading anything: a list with no usable key in it cannot
	-- verify whatever the library would have said.
	local keys = {}
	for _index, hex in ipairs(trusted_keys or {}) do
		local key = fromHex(hex, Signature.KEY_BYTES)
		if key then
			table.insert(keys, key)
		else
			logger.warn("Crossbill: ignoring a trusted key that is not", Signature.KEY_BYTES, "bytes of hex")
		end
	end

	if #keys == 0 then
		logger.warn("Crossbill: no usable trusted key to verify against")
		return false
	end

	local lib = crypto()
	if not lib then
		return false
	end

	local ffi = require("ffi")
	local message = ffi.cast("const unsigned char *", data)
	local sig = ffi.cast("const unsigned char *", signature)

	for _index, key in ipairs(keys) do
		if lib.ED25519_verify(message, #data, sig, ffi.cast("const unsigned char *", key)) == 1 then
			return true
		end
	end

	return false
end

return Signature
