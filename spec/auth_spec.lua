local AuthFailed = require("modules/auth_failed")

-- `modules/network` is the plugin's own module rather than one of KOReader's,
-- so it cannot be shadowed from spec/support, and it is the one module that must
-- not run under test. Seeding the package cache before requiring auth binds it
-- to this fake for the whole run; the real module is put back afterwards (see
-- spec/api_client_spec.lua).
local NetworkFake = {
	form_result = {},
	json_result = {},
	posted_forms = {},
	posted_json = {},
}

--- Answer `postForm` with whatever the current test has queued
-- @param url string The URL being posted to
-- @param data table The credentials the module sent
-- @return number|nil, table|nil, string|nil The queued status, body and error
function NetworkFake.postForm(url, data)
	table.insert(NetworkFake.posted_forms, { url = url, data = data })
	return NetworkFake.form_result[1], NetworkFake.form_result[2], NetworkFake.form_result[3]
end

--- Answer `postJson` with whatever the current test has queued
-- @param url string The URL being posted to
-- @param data table The payload the module sent
-- @return number|nil, table|nil, string|nil The queued status, body and error
function NetworkFake.postJson(url, data)
	table.insert(NetworkFake.posted_json, { url = url, data = data })
	return NetworkFake.json_result[1], NetworkFake.json_result[2], NetworkFake.json_result[3]
end

--- Forget the requests made and the queued answers
function NetworkFake.reset()
	NetworkFake.form_result = {}
	NetworkFake.json_result = {}
	NetworkFake.posted_forms = {}
	NetworkFake.posted_json = {}
end

local real_network = package.loaded["modules/network"]
package.loaded["modules/network"] = NetworkFake
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

describe("Auth", function()
	before_each(function()
		NetworkFake.reset()
	end)

	describe("login", function()
		it("reports missing credentials as an authentication failure", function()
			-- The reader has something to fix, and the dialog that says so is
			-- chosen by the error's type.
			local _, err = Auth:new(settingsWith({})):login()

			assert.is_true(AuthFailed.is(err))
			assert.are.equal("Username or password not configured", AuthFailed.message(err))
			assert.are.same({}, NetworkFake.posted_forms)
		end)

		it("reports credentials the server rejected as an authentication failure", function()
			NetworkFake.form_result = { 401, nil }

			local _, err = Auth:new(settingsWith({ username = "ada", password = "wrong" })):login()

			assert.is_true(AuthFailed.is(err))
			assert.are.equal("Login failed: 401", AuthFailed.message(err))
		end)

		it("leaves a network failure as the plain message it was", function()
			-- Nothing is wrong with the reader's password, so telling them their
			-- authentication failed would send them to change one that works.
			NetworkFake.form_result = { nil, nil, "Connection refused" }

			local _, err = Auth:new(settingsWith({ username = "ada", password = "secret" })):login()

			assert.is_false(AuthFailed.is(err))
			assert.are.equal("Connection refused", err)
		end)

		it("hands back the token the server issued", function()
			NetworkFake.form_result = { 200, { access_token = "fresh", refresh_token = "r", expires_in = 3600 } }
			local settings = settingsWith({ username = "ada", password = "secret" })

			local token, err = Auth:new(settings):login()

			assert.are.equal("fresh", token)
			assert.is_nil(err)
			assert.are.equal("fresh", settings.tokens.access)
		end)
	end)

	describe("getValidToken", function()
		it("forgets the stored tokens when the refresh is refused, and logs in instead", function()
			NetworkFake.json_result = { 401, nil }
			NetworkFake.form_result = { 200, { access_token = "fresh", expires_in = 3600 } }
			local settings = settingsWith({ refresh_token = "stale", username = "ada", password = "secret" })

			local token, err = Auth:new(settings):getValidToken()

			assert.are.equal("fresh", token)
			assert.is_nil(err)
			assert.are.equal(1, settings.cleared)
			assert.are.equal(1, #NetworkFake.posted_json)
			assert.are.equal(1, #NetworkFake.posted_forms)
		end)

		it("reports the login's failure, not the refresh's", function()
			-- The refresh is an optimisation; what the reader is told about is
			-- the login that was tried after it.
			NetworkFake.json_result = { 401, nil }
			local settings = settingsWith({ refresh_token = "stale" })

			local _, err = Auth:new(settings):getValidToken()

			assert.is_true(AuthFailed.is(err))
			assert.are.equal("Username or password not configured", AuthFailed.message(err))
		end)
	end)
end)
