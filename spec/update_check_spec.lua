--[[
`modules/network` is the plugin's own module rather than one of KOReader's, so
it cannot be shadowed from spec/support (see spec/api_client_spec.lua). Seeding
the package cache before requiring the update check binds it to this fake for
the whole run; the real module is put back so nothing else sees the fake.
]]

local NetworkFake = { result = {}, requests = {} }

--- Answer `getJson` with whatever the current test has queued
-- @param url string The URL being fetched
-- @param token string|nil The bearer token
-- @param extra_headers table|nil The headers the caller added
-- @return number|nil, table|nil, string|nil The queued status, body and error
function NetworkFake.getJson(url, token, extra_headers)
	table.insert(NetworkFake.requests, { url = url, token = token, headers = extra_headers })
	return NetworkFake.result[1], NetworkFake.result[2], NetworkFake.result[3]
end

--- Queue the tuple the next `getJson` should return
-- @param code number|nil The HTTP status
-- @param body table|nil The decoded response body
-- @param err string|nil The error message
local function answerWith(code, body, err)
	NetworkFake.result = { code, body, err }
end

local real_network = package.loaded["modules/network"]
package.loaded["modules/network"] = NetworkFake
local UpdateCheck = require("modules/update_check")
package.loaded["modules/network"] = real_network

local meta = require("_meta")

-- Stands for a field the service left out. A plain nil cannot say that: a
-- table of overrides carrying one has no such key to iterate over.
local ABSENT = {}

--- A GitHub release body, with the fields a test cares about overridden
-- @param overrides table|nil Fields to replace, or to set to ABSENT to drop
-- @return table The release
local function release(overrides)
	local body = {
		tag_name = "v9.9.9",
		html_url = "https://github.com/Crossbill-App/koreader-plugin/releases/tag/v9.9.9",
		assets = {
			{ name = "crossbill.koplugin.zip", browser_download_url = "https://example.test/crossbill.koplugin.zip" },
		},
	}

	for key, value in pairs(overrides or {}) do
		body[key] = value ~= ABSENT and value or nil
	end

	return body
end

describe("UpdateCheck.compareVersions", function()
	it("calls identical versions equal", function()
		assert.are.equal(0, UpdateCheck.compareVersions("1.2.3", "1.2.3"))
	end)

	it("ignores a leading v on either side", function()
		assert.are.equal(0, UpdateCheck.compareVersions("v1.2.3", "1.2.3"))
		assert.are.equal(0, UpdateCheck.compareVersions("1.2.3", "v1.2.3"))
	end)

	it("orders by major, then minor, then patch", function()
		assert.are.equal(-1, UpdateCheck.compareVersions("0.12.0", "1.0.0"))
		assert.are.equal(-1, UpdateCheck.compareVersions("0.12.0", "0.13.0"))
		assert.are.equal(-1, UpdateCheck.compareVersions("0.12.0", "0.12.1"))
		assert.are.equal(1, UpdateCheck.compareVersions("1.0.0", "0.99.99"))
	end)

	it("compares the numbers rather than the text", function()
		-- As text, "10" sorts below "9"
		assert.are.equal(1, UpdateCheck.compareVersions("10.0.0", "9.0.0"))
		assert.are.equal(1, UpdateCheck.compareVersions("1.10.0", "1.9.0"))
		assert.are.equal(1, UpdateCheck.compareVersions("1.0.10", "1.0.9"))
	end)

	it("refuses anything that is not three numbers", function()
		assert.is_nil(UpdateCheck.compareVersions("0.13", "0.12.0"))
		assert.is_nil(UpdateCheck.compareVersions("release-2", "0.12.0"))
		assert.is_nil(UpdateCheck.compareVersions("1.0.0-rc1", "0.12.0"))
		assert.is_nil(UpdateCheck.compareVersions("0.12.0", "1.0.0.1"))
		assert.is_nil(UpdateCheck.compareVersions(nil, "0.12.0"))
		assert.is_nil(UpdateCheck.compareVersions("", "0.12.0"))
	end)
end)

describe("UpdateCheck.check", function()
	before_each(function()
		NetworkFake.requests = {}
		answerWith(nil, nil, nil)
	end)

	it("names the plugin to the release service", function()
		answerWith(200, release())

		UpdateCheck.check()

		local request = NetworkFake.requests[1]
		assert.are.equal(meta.update_check_url, request.url)
		assert.is_nil(request.token)
		assert.are.equal("koreader-plugin/" .. meta.version, request.headers["User-Agent"])
	end)

	it("reports a newer release as an update", function()
		answerWith(200, release({ tag_name = "v9.9.9" }))

		local completed, result = UpdateCheck.check()

		assert.is_true(completed)
		assert.is_true(result.update_available)
		assert.is_false(result.ahead)
		assert.are.equal("9.9.9", result.latest)
		assert.are.equal(meta.version, result.current)
	end)

	it("reports the running version as the latest when they match", function()
		answerWith(200, release({ tag_name = "v" .. meta.version }))

		local completed, result = UpdateCheck.check()

		assert.is_true(completed)
		assert.is_false(result.update_available)
		assert.is_false(result.ahead)
	end)

	it("says the plugin is ahead rather than up to date", function()
		answerWith(200, release({ tag_name = "v0.0.1" }))

		local completed, result = UpdateCheck.check()

		assert.is_true(completed)
		assert.is_false(result.update_available)
		assert.is_true(result.ahead)
		assert.are.equal("0.0.1", result.latest)
	end)

	it("finds the archive the release workflow publishes", function()
		answerWith(200, release())

		local completed, result = UpdateCheck.check()

		assert.is_true(completed)
		assert.are.equal("https://example.test/crossbill.koplugin.zip", result.download_url)
	end)

	it("still reports the release when no archive matches", function()
		answerWith(
			200,
			release({ assets = { { name = "notes.txt", browser_download_url = "https://example.test/x" } } })
		)

		local completed, result = UpdateCheck.check()

		assert.is_true(completed)
		assert.is_true(result.update_available)
		assert.is_nil(result.download_url)
	end)

	it("still reports the release when it carries no assets at all", function()
		answerWith(200, release({ assets = ABSENT }))

		local completed, result = UpdateCheck.check()

		assert.is_true(completed)
		assert.is_nil(result.download_url)
	end)

	it("falls back to the homepage when the release names no page of its own", function()
		answerWith(200, release({ html_url = ABSENT }))

		local completed, result = UpdateCheck.check()

		assert.is_true(completed)
		assert.are.equal(meta.homepage, result.release_url)
	end)

	it("fails when the request never reached the service", function()
		answerWith(nil, nil, "connection refused")

		local completed, result, err = UpdateCheck.check()

		assert.is_false(completed)
		assert.is_nil(result)
		assert.is_truthy(err:find("connection refused", 1, true))
	end)

	it("fails on any status other than 200, naming it", function()
		answerWith(403, {})

		local completed, result, err = UpdateCheck.check()

		assert.is_false(completed)
		assert.is_nil(result)
		assert.is_truthy(err:find("403", 1, true))
	end)

	it("fails when the answer was not a release", function()
		answerWith(200, nil)

		local completed, result, err = UpdateCheck.check()

		assert.is_false(completed)
		assert.is_nil(result)
		assert.is_truthy(err)
	end)

	it("fails when the release carries no tag", function()
		answerWith(200, release({ tag_name = ABSENT }))

		local completed, result, err = UpdateCheck.check()

		assert.is_false(completed)
		assert.is_nil(result)
		assert.is_truthy(err)
	end)

	it("names the tag it could not read", function()
		answerWith(200, release({ tag_name = "release-2" }))

		local completed, result, err = UpdateCheck.check()

		assert.is_false(completed)
		assert.is_nil(result)
		assert.is_truthy(err:find("release-2", 1, true))
	end)

	it("fails without asking anything when no service is configured", function()
		local configured = meta.update_check_url
		meta.update_check_url = nil

		local completed, result, err = UpdateCheck.check()

		meta.update_check_url = configured

		assert.is_false(completed)
		assert.is_nil(result)
		assert.is_truthy(err)
		assert.are.equal(0, #NetworkFake.requests)
	end)
end)
