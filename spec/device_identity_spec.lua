local Device = require("device")
local GlobalSettingsFake = require("global_settings_fake")
local random = require("random")

-- The key `Settings` persists under inside G_reader_settings, and the key the
-- generated UUID takes within it.
local SETTINGS_KEY = "crossbill_sync"
local UUID_KEY = "device_uuid"

--- Load a fresh copy of the module
-- The device id is computed once per KOReader run and cached in a module local,
-- which outlives a single test; dropping the module from the package cache is
-- what gives each test the run-once behaviour rather than the previous test's
-- answer.
-- @return table A DeviceIdentity with an empty cache
local function freshDeviceIdentity()
	package.loaded["modules/device_identity"] = nil
	return require("modules/device_identity")
end

describe("DeviceIdentity", function()
	local global
	local DeviceIdentity

	before_each(function()
		global = GlobalSettingsFake.install()
		Device.reset()
		random.reset()
		DeviceIdentity = freshDeviceIdentity()
	end)

	after_each(function()
		global.uninstall()
		package.loaded["modules/device_identity"] = nil
	end)

	--- Read the UUID the plugin has persisted for itself
	-- @return string|nil The stored UUID
	local function storedUuid()
		local stored = global.store[SETTINGS_KEY]
		return stored and stored[UUID_KEY]
	end

	describe("getDeviceId", function()
		it("joins the model to a short form of the UUID", function()
			Device.model = "PocketBook628"
			G_reader_settings:saveSetting("device_id", "abcdef01-2345-6789-abcd-ef0123456789")

			assert.are.equal("PocketBook628-abcdef01", DeviceIdentity.getDeviceId())
		end)

		it("prefers KOReader's own device UUID", function()
			G_reader_settings:saveSetting("device_id", "abcdef01-2345-6789-abcd-ef0123456789")

			DeviceIdentity.getDeviceId()

			-- Nothing had to be generated, so nothing was persisted.
			assert.is_nil(storedUuid())
		end)

		it("falls back to a UUID of its own when KOReader has none", function()
			random.setNextUuids("11112222-3333-4444-5555-666677778888")

			assert.are.equal("TestReader-11112222", DeviceIdentity.getDeviceId())
		end)

		it("ignores an empty KOReader UUID", function()
			G_reader_settings:saveSetting("device_id", "")
			random.setNextUuids("11112222-3333-4444-5555-666677778888")

			assert.are.equal("TestReader-11112222", DeviceIdentity.getDeviceId())
		end)

		it("persists the UUID it generated", function()
			random.setNextUuids("11112222-3333-4444-5555-666677778888")

			DeviceIdentity.getDeviceId()

			assert.are.equal("11112222-3333-4444-5555-666677778888", storedUuid())
		end)

		it("reuses the persisted UUID on a later run, so the id is stable", function()
			random.setNextUuids("11112222-3333-4444-5555-666677778888")
			local first = DeviceIdentity.getDeviceId()

			local second = freshDeviceIdentity().getDeviceId()

			assert.are.equal(first, second)
			assert.are.equal("TestReader-11112222", second)
		end)

		it("does not generate a second UUID once one is stored", function()
			random.setNextUuids("11112222-3333-4444-5555-666677778888")
			DeviceIdentity.getDeviceId()

			freshDeviceIdentity().getDeviceId()

			assert.are.equal("11112222-3333-4444-5555-666677778888", storedUuid())
		end)

		it("computes the id once per run", function()
			random.setNextUuids("11112222-3333-4444-5555-666677778888")
			local first = DeviceIdentity.getDeviceId()

			-- A later model change cannot reach the cached answer.
			Device.model = "SomethingElse"

			assert.are.equal(first, DeviceIdentity.getDeviceId())
		end)

		it("strips the UUID's hyphens before taking its first eight characters", function()
			random.setNextUuids("1-2-3-4-56789abcdef")

			assert.are.equal("TestReader-12345678", DeviceIdentity.getDeviceId())
		end)

		it("lowercases the suffix", function()
			random.setNextUuids("ABCDEF01-2345-6789-ABCD-EF0123456789")

			assert.are.equal("TestReader-abcdef01", DeviceIdentity.getDeviceId())
		end)

		it("calls an unknown model unknown", function()
			Device.model = nil
			random.setNextUuids("11112222-3333-4444-5555-666677778888")

			assert.are.equal("unknown-11112222", DeviceIdentity.getDeviceId())
		end)

		it("calls an empty model unknown", function()
			Device.model = ""
			random.setNextUuids("11112222-3333-4444-5555-666677778888")

			assert.are.equal("unknown-11112222", DeviceIdentity.getDeviceId())
		end)

		it("truncates a long model to keep within the server's 100 characters", function()
			Device.model = string.rep("M", 200)
			random.setNextUuids("11112222-3333-4444-5555-666677778888")

			local device_id = DeviceIdentity.getDeviceId()

			assert.are.equal(100, #device_id)
			assert.are.equal("-11112222", device_id:sub(-9))
		end)

		it("leaves a model that already fits alone", function()
			Device.model = string.rep("M", 91)
			random.setNextUuids("11112222-3333-4444-5555-666677778888")

			assert.are.equal(100, #DeviceIdentity.getDeviceId())
		end)
	end)
end)
