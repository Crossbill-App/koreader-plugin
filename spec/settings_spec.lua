local Settings = require("modules/settings")
local GlobalSettingsFake = require("global_settings_fake")

-- The key `Settings` persists under inside G_reader_settings.
local SETTINGS_KEY = "crossbill_sync"

describe("Settings", function()
	local global

	before_each(function()
		global = GlobalSettingsFake.install()
	end)

	after_each(function()
		global.uninstall()
	end)

	--- Seed the values a previous run would have persisted
	-- @param stored table The stored crossbill settings table
	local function persisted(stored)
		global.store[SETTINGS_KEY] = stored
	end

	--- Read back what the plugin has written to the global settings
	-- @return table|nil The persisted crossbill settings table
	local function written()
		return global.store[SETTINGS_KEY]
	end

	describe("load", function()
		it("applies the defaults on a first run", function()
			local settings = Settings:new():load()

			assert.are.equal("http://localhost:8000", settings:getBaseUrl())
			assert.are.equal("", settings:getUsername())
			assert.are.equal("", settings:getPassword())
			assert.is_false(settings:isAutosyncEnabled())
			assert.is_true(settings:isSessionTrackingEnabled())
			assert.are.equal(60, settings:getMinReadingSessionDuration())
			assert.is_nil(settings:getAccessToken())
		end)

		it("keeps persisted values instead of overwriting them with defaults", function()
			persisted({ base_url = "https://crossbill.example", username = "ada" })

			local settings = Settings:new():load()

			assert.are.equal("https://crossbill.example", settings:getBaseUrl())
			assert.are.equal("ada", settings:getUsername())
		end)

		it("fills in only the keys a partially persisted table is missing", function()
			persisted({ base_url = "https://crossbill.example" })

			assert.is_true(Settings:new():load():isSessionTrackingEnabled())
		end)

		it("keeps a persisted false, rather than treating it as missing", function()
			persisted({ session_tracking_enabled = false })

			assert.is_false(Settings:new():load():isSessionTrackingEnabled())
		end)

		it("is chainable", function()
			local settings = Settings:new()

			assert.are.equal(settings, settings:load())
		end)
	end)

	describe("get and set", function()
		it("loads lazily on the first get", function()
			persisted({ base_url = "https://crossbill.example" })

			assert.are.equal("https://crossbill.example", Settings:new():get("base_url"))
		end)

		it("loads lazily on the first set", function()
			persisted({ username = "ada" })
			local settings = Settings:new()

			settings:set("base_url", "https://elsewhere.example")

			assert.are.equal("ada", settings:getUsername())
		end)

		it("does not persist until save is called", function()
			Settings:new():load():set("username", "ada")

			assert.is_nil(written())
		end)

		it("persists the whole settings table on save", function()
			Settings:new():load():set("username", "ada"):save()

			assert.are.equal("ada", written().username)
		end)
	end)

	describe("setBaseUrl", function()
		it("stores the URL as given", function()
			local settings = Settings:new():load():setBaseUrl("https://crossbill.example")

			assert.are.equal("https://crossbill.example", settings:getBaseUrl())
		end)

		it("strips a single trailing slash", function()
			local settings = Settings:new():load():setBaseUrl("https://crossbill.example/")

			assert.are.equal("https://crossbill.example", settings:getBaseUrl())
		end)

		it("leaves an internal path intact", function()
			local settings = Settings:new():load():setBaseUrl("https://crossbill.example/api")

			assert.are.equal("https://crossbill.example/api", settings:getBaseUrl())
		end)
	end)

	describe("hasCredentials", function()
		it("is false before anything is configured", function()
			assert.is_false(Settings:new():load():hasCredentials())
		end)

		it("is false with a username but no password", function()
			assert.is_false(Settings:new():load():setUsername("ada"):hasCredentials())
		end)

		it("is false with a password but no username", function()
			assert.is_false(Settings:new():load():setPassword("hunter2"):hasCredentials())
		end)

		it("is true once both are set", function()
			local settings = Settings:new():load():setUsername("ada"):setPassword("hunter2")

			assert.is_true(settings:hasCredentials())
		end)
	end)

	describe("toggles", function()
		it("flips autosync and persists it", function()
			local settings = Settings:new():load()

			assert.is_true(settings:toggleAutosync())
			assert.is_true(settings:isAutosyncEnabled())
			assert.is_true(written().autosync_enabled)

			assert.is_false(settings:toggleAutosync())
			assert.is_false(written().autosync_enabled)
		end)

		it("flips session tracking and persists it", function()
			local settings = Settings:new():load()

			assert.is_false(settings:toggleSessionTracking())
			assert.is_false(settings:isSessionTrackingEnabled())
			assert.is_false(written().session_tracking_enabled)
		end)
	end)

	describe("tokens", function()
		it("stores the access token and persists immediately", function()
			Settings:new():load():setTokens("access-abc")

			assert.are.equal("access-abc", written().access_token)
		end)

		it("stores the refresh token when one is supplied", function()
			local settings = Settings:new():load():setTokens("access-abc", "refresh-xyz")

			assert.are.equal("refresh-xyz", settings:getRefreshToken())
		end)

		it("keeps the previous refresh token when a refresh omits it", function()
			local settings = Settings:new():load():setTokens("access-abc", "refresh-xyz")

			settings:setTokens("access-def")

			assert.are.equal("access-def", settings:getAccessToken())
			assert.are.equal("refresh-xyz", settings:getRefreshToken())
		end)

		it("turns expires_in into an absolute expiry timestamp", function()
			local before = os.time()

			local settings = Settings:new():load():setTokens("access-abc", nil, 3600)

			local expires_at = settings:getTokenExpiresAt()
			assert.is_true(expires_at >= before + 3600)
			assert.is_true(expires_at <= os.time() + 3600)
		end)

		it("leaves the expiry unset when expires_in is omitted", function()
			assert.is_nil(Settings:new():load():setTokens("access-abc"):getTokenExpiresAt())
		end)

		it("clears every token and persists the clearing", function()
			local settings = Settings:new():load():setTokens("access-abc", "refresh-xyz", 3600)

			settings:clearTokens()

			assert.is_nil(settings:getAccessToken())
			assert.is_nil(settings:getRefreshToken())
			assert.is_nil(settings:getTokenExpiresAt())
			assert.is_nil(written().access_token)
		end)
	end)

	describe("updateServerConfig", function()
		it("normalizes the URL, stores the credentials and persists in one go", function()
			Settings:new():load():updateServerConfig("https://crossbill.example/", "ada", "hunter2")

			local stored = written()
			assert.are.equal("https://crossbill.example", stored.base_url)
			assert.are.equal("ada", stored.username)
			assert.are.equal("hunter2", stored.password)
		end)

		it("survives a round trip through a fresh Settings instance", function()
			Settings:new():load():updateServerConfig("https://crossbill.example", "ada", "hunter2")

			local reloaded = Settings:new():load()

			assert.are.equal("https://crossbill.example", reloaded:getBaseUrl())
			assert.is_true(reloaded:hasCredentials())
		end)
	end)
end)
