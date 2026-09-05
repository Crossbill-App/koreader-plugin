local AuthFailed = require("modules/auth_failed")
local UpgradeRequired = require("modules/upgrade_required")
local FakeNetwork = require("fake_network")

-- `modules/network` is the plugin's own module rather than one of KOReader's,
-- so it cannot be shadowed from spec/support, and it is the one module that must
-- not run under test. Seeding the package cache before requiring auth binds it
-- to this fake for the whole run; the real module is put back afterwards (see
-- spec/api_client_spec.lua).
local network = FakeNetwork:new()

local real_network = package.loaded["modules/network"]
package.loaded["modules/network"] = network
local Auth = require("modules/auth")
package.loaded["modules/network"] = real_network

--- Build the settings stand-in Auth reads its credentials and tokens from
-- @param fields table|nil Values the stand-in starts out holding
-- @return table The settings stand-in, recording what was written to it
local function settingsWith(fields)
	local state = fields or {}
	return {
		cleared = 0,
		getApiUrl = function()
			return "https://crossbill.example/api/v1"
		end,
		getUsername = function()
			return state.username or ""
		end,
		getPassword = function()
			return state.password or ""
		end,
		getAccessToken = function()
			return state.access_token
		end,
		getRefreshToken = function()
			return state.refresh_token
		end,
		getTokenExpiresAt = function()
			return state.expires_at
		end,
		setTokens = function(self, access, refresh, expires_in)
			self.tokens = { access = access, refresh = refresh, expires_in = expires_in }
		end,
		clearTokens = function(self)
			self.cleared = self.cleared + 1
		end,
	}
end

-- What the server answers a plugin it will no longer serve, on any route
local REFUSAL_BODY = {
	detail = {
		code = "client_upgrade_required",
		client = "koreader-plugin",
		min_supported_version = "0.13.0",
		received_version = "0.12.0",
		update_url = "https://github.com/Crossbill-App/koreader-plugin",
	},
}

describe("Auth", function()
	before_each(function()
		network.reset()
	end)

	describe("login", function()
		it("reports missing credentials as an authentication failure", function()
			-- The reader has something to fix, and the dialog that says so is
			-- chosen by the error's type.
			local _, err = Auth:new(settingsWith({})):login()

			assert.is_true(AuthFailed.is(err))
			assert.are.equal("Username or password not configured", AuthFailed.message(err))
			assert.are.same({}, network.posted_forms)
		end)

		it("reports credentials the server rejected as an authentication failure", function()
			network.setFormResult(401, nil)

			local _, err = Auth:new(settingsWith({ username = "ada", password = "wrong" })):login()

			assert.is_true(AuthFailed.is(err))
			assert.are.equal("Login failed: 401", AuthFailed.message(err))
		end)

		it("leaves a network failure as the plain message it was", function()
			-- Nothing is wrong with the reader's password, so telling them their
			-- authentication failed would send them to change one that works.
			network.setFormResult(nil, nil, "Connection refused")

			local _, err = Auth:new(settingsWith({ username = "ada", password = "secret" })):login()

			assert.is_false(AuthFailed.is(err))
			assert.are.equal("Connection refused", err)
		end)

		it("raises the server's refusal instead of blaming the credentials", function()
			-- Every request carries the version header, so a plugin the server has
			-- stopped serving is refused at the login endpoint, before it has a
			-- token to be turned away over. Read as an authentication failure it
			-- would put the credentials dialog in front of a working password.
			network.setFormResult(426, REFUSAL_BODY)

			local ok, err = pcall(function()
				return Auth:new(settingsWith({ username = "ada", password = "secret" })):login()
			end)

			assert.is_false(ok)
			assert.is_true(UpgradeRequired.is(err))
			assert.is_false(AuthFailed.is(err))
		end)

		it("raises it carrying the versions the server named", function()
			network.setFormResult(426, REFUSAL_BODY)

			local _, err = pcall(function()
				return Auth:new(settingsWith({ username = "ada", password = "secret" })):login()
			end)

			assert.are.equal("0.12.0", err.received_version)
			assert.are.equal("0.13.0", err.min_supported_version)
		end)

		it("hands back the token the server issued", function()
			network.setFormResult(200, { access_token = "fresh", refresh_token = "r", expires_in = 3600 })
			local settings = settingsWith({ username = "ada", password = "secret" })

			local token, err = Auth:new(settings):login()

			assert.are.equal("fresh", token)
			assert.is_nil(err)
			assert.are.equal("fresh", settings.tokens.access)
		end)
	end)

	describe("getValidToken", function()
		it("forgets the stored tokens when the refresh is refused, and logs in instead", function()
			network.setPostResult(401, nil)
			network.setFormResult(200, { access_token = "fresh", expires_in = 3600 })
			local settings = settingsWith({ refresh_token = "stale", username = "ada", password = "secret" })

			local token, err = Auth:new(settings):getValidToken()

			assert.are.equal("fresh", token)
			assert.is_nil(err)
			assert.are.equal(1, settings.cleared)
			assert.are.equal(1, #network.posted_json)
			assert.are.equal(1, #network.posted_forms)
		end)

		it("raises a refusal met by the refresh instead of trying the login", function()
			-- The login would only be told the same thing, and the stored tokens
			-- are not what the server objected to.
			network.setPostResult(426, REFUSAL_BODY)
			local settings = settingsWith({ refresh_token = "stale", username = "ada", password = "secret" })

			local ok, err = pcall(function()
				return Auth:new(settings):getValidToken()
			end)

			assert.is_false(ok)
			assert.is_true(UpgradeRequired.is(err))
			assert.are.equal("0.12.0", err.received_version)
			assert.are.equal("0.13.0", err.min_supported_version)
			assert.are.same({}, network.posted_forms)
			assert.are.equal(0, settings.cleared)
		end)

		it("reports the login's failure, not the refresh's", function()
			-- The refresh is an optimisation; what the reader is told about is
			-- the login that was tried after it.
			network.setPostResult(401, nil)
			local settings = settingsWith({ refresh_token = "stale" })

			local _, err = Auth:new(settings):getValidToken()

			assert.is_true(AuthFailed.is(err))
			assert.are.equal("Username or password not configured", AuthFailed.message(err))
		end)
	end)
end)
