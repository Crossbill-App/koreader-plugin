--[[
Busted runs plain Lua 5.1, so `require("ffi")` fails here exactly as it would on
a KOReader too old to ship LibreSSL. That makes this spec the fail-closed path:
what the module does when it cannot verify anything is the behaviour that keeps
an unverified archive off a reader's device, so it is the behaviour worth
pinning down. The verification itself is LibreSSL's, and is exercised on device.
]]

local logger = require("logger")
local Signature = require("modules/update/signature")

-- Shaped like a real key, so a test that should fail for another reason is not
-- quietly failing on the hex instead.
local VALID_KEY = "00dbe21ce3037de10be4f08ef7f8c7a08560883f69a02304c18ee803a122c731"
local ANOTHER_VALID_KEY = "3b6a27bcceb6a42d62a3a8d02a6f0d73653215771de243a63ac048a18b59da29"
local SIGNATURE = string.rep("\1", Signature.SIGNATURE_BYTES)

describe("Signature.isAvailable", function()
	it("says no where there is no Ed25519 to reach", function()
		assert.is_false(Signature.isAvailable())
	end)

	it("does not go looking a second time", function()
		-- The answer is cached, so a device without it pays for the failed
		-- load once rather than on every attempt.
		local warn = spy.on(logger, "warn")

		Signature.isAvailable()
		Signature.isAvailable()

		assert.spy(warn).was_not_called()
		logger.warn:revert()
	end)
end)

describe("Signature.verify", function()
	it("refuses when it cannot verify at all", function()
		assert.is_false(Signature.verify("payload", SIGNATURE, { VALID_KEY }))
	end)

	it("refuses a signature of the wrong length", function()
		assert.is_false(Signature.verify("payload", string.rep("\1", 63), { VALID_KEY }))
		assert.is_false(Signature.verify("payload", string.rep("\1", 65), { VALID_KEY }))
		assert.is_false(Signature.verify("payload", "", { VALID_KEY }))
	end)

	it("refuses anything that is not a pair of strings", function()
		assert.is_false(Signature.verify(nil, SIGNATURE, { VALID_KEY }))
		assert.is_false(Signature.verify("payload", nil, { VALID_KEY }))
		assert.is_false(Signature.verify({}, SIGNATURE, { VALID_KEY }))
	end)

	it("refuses when no key is usable, without reaching for the library", function()
		local warn = spy.on(logger, "warn")

		assert.is_false(Signature.verify("payload", SIGNATURE, {}))
		assert.is_false(Signature.verify("payload", SIGNATURE, nil))

		assert.spy(warn).was_called()
		logger.warn:revert()
	end)

	it("discards a key that is not 32 bytes of hex and keeps the rest", function()
		-- The placeholder in keys.lua and a mistyped paste both land here; the
		-- list must not be poisoned by one bad entry.
		local warn = spy.on(logger, "warn")

		Signature.verify("payload", SIGNATURE, {
			"not hex at all",
			VALID_KEY:sub(1, 60),
			VALID_KEY .. "ff",
			42,
			ANOTHER_VALID_KEY,
		})

		-- Four bad entries warned about, and the good one still got as far as
		-- the library, which is the only reason the answer is false.
		assert.spy(warn).was_called(4)
		logger.warn:revert()
	end)
end)

describe("the trusted key list", function()
	local keys = require("modules/update/keys")

	it("is a non-empty list", function()
		assert.are.equal("table", type(keys))
		assert.is_true(#keys > 0)
	end)

	it("holds nothing but 64-character hex", function()
		for _index, key in ipairs(keys) do
			assert.are.equal("string", type(key))
			assert.are.equal(64, #key)
			assert.is_nil(key:find("[^0-9a-fA-F]"))
		end
	end)
end)
