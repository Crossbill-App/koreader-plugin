local json = require("json")

-- `modules/network` is the plugin's own module, not one of KOReader's, so it
-- cannot be shadowed by a file in spec/support: `crossbill.koplugin` comes first
-- on the path. It is also the one module that must not run under test, being
-- the one that opens sockets. Seeding the package cache before requiring the
-- api client binds the client to this fake for the whole run; the real module is
-- put back afterwards so nothing else sees the fake.
local NetworkFake = {
	get_result = { nil, nil, nil },
	requested = {},
}

--- Answer `getJson` with whatever the current test has queued
-- @param url string The URL being fetched
-- @param token string|nil The bearer token
-- @return number|nil, table|nil, string|nil The queued status, body and error
function NetworkFake.getJson(url, token)
	table.insert(NetworkFake.requested, { url = url, token = token })
	return NetworkFake.get_result[1], NetworkFake.get_result[2], NetworkFake.get_result[3]
end

--- Queue the tuple the next `getJson` should return
-- @param code number|nil The HTTP status
-- @param body table|nil The decoded response body
-- @param err string|nil The error message
function NetworkFake.setGetResult(code, body, err)
	NetworkFake.get_result = { code, body, err }
end

--- Forget the requests made and the queued answer
function NetworkFake.reset()
	NetworkFake.get_result = { nil, nil, nil }
	NetworkFake.requested = {}
end

local real_network = package.loaded["modules/network"]
package.loaded["modules/network"] = NetworkFake
local ApiClient = require("modules/api_client")
package.loaded["modules/network"] = real_network

local BASE_URL = "https://crossbill.example"
local CLIENT_BOOK_ID = "b9c1"
local TOKEN = "access-abc"

--- Build an ApiClient whose auth hands out the given token
-- @param token string|nil The token, or nil to fail authentication
-- @param auth_err string|nil The authentication error
-- @return table The ApiClient instance
local function clientWithToken(token, auth_err)
	return ApiClient:new({
		getBaseUrl = function()
			return BASE_URL
		end,
	}, {
		getValidToken = function()
			return token, auth_err
		end,
	})
end

describe("ApiClient", function()
	before_each(function()
		NetworkFake.reset()
	end)

	describe("getHighlights", function()
		it("fetches the book's highlights from the ereader endpoint", function()
			NetworkFake.setGetResult(200, { items = {} })

			clientWithToken(TOKEN):getHighlights(CLIENT_BOOK_ID)

			assert.are.equal(
				BASE_URL .. "/api/v1/ereader/books/" .. CLIENT_BOOK_ID .. "/highlights",
				NetworkFake.requested[1].url
			)
			assert.are.equal(TOKEN, NetworkFake.requested[1].token)
		end)

		it("returns the status and the items on success", function()
			NetworkFake.setGetResult(200, { items = { { text = "one" }, { text = "two" } } })

			local code, items, err = clientWithToken(TOKEN):getHighlights(CLIENT_BOOK_ID)

			assert.are.equal(200, code)
			assert.are.equal(2, #items)
			assert.are.equal("one", items[1].text)
			assert.is_nil(err)
		end)

		it("turns the decoder's empty-array marker into a plain table", function()
			-- A book with no highlights decodes to the marker rather than to a
			-- table, which the caller would otherwise be handed and iterate.
			NetworkFake.setGetResult(200, { items = json.EMPTY_ARRAY })

			local code, items = clientWithToken(TOKEN):getHighlights(CLIENT_BOOK_ID)

			assert.are.equal(200, code)
			assert.are.same({}, items)
			assert.are_not.equal(json.EMPTY_ARRAY, items)
		end)

		it("returns an empty list when the response carries no items at all", function()
			NetworkFake.setGetResult(200, {})

			local code, items = clientWithToken(TOKEN):getHighlights(CLIENT_BOOK_ID)

			assert.are.equal(200, code)
			assert.are.same({}, items)
		end)

		it("copies the items rather than handing back the response's own table", function()
			local body = { items = { { text = "one" } } }
			NetworkFake.setGetResult(200, body)

			local _, items = clientWithToken(TOKEN):getHighlights(CLIENT_BOOK_ID)

			assert.are_not.equal(body.items, items)
		end)

		it("reports a book the server does not know without an error", function()
			-- 404 is an answer, not a failure: the book has never been synced.
			NetworkFake.setGetResult(404, nil)

			local code, items, err = clientWithToken(TOKEN):getHighlights(CLIENT_BOOK_ID)

			assert.are.equal(404, code)
			assert.is_nil(items)
			assert.is_nil(err)
		end)

		it("reports a server failure with its status", function()
			NetworkFake.setGetResult(500, nil)

			local code, items, err = clientWithToken(TOKEN):getHighlights(CLIENT_BOOK_ID)

			assert.are.equal(500, code)
			assert.is_nil(items)
			assert.are.equal("Fetch failed: 500", err)
		end)

		it("treats a 200 with no body as a failure", function()
			NetworkFake.setGetResult(200, nil)

			local code, items, err = clientWithToken(TOKEN):getHighlights(CLIENT_BOOK_ID)

			assert.are.equal(200, code)
			assert.is_nil(items)
			assert.is_not_nil(err)
		end)

		it("passes a network error straight back", function()
			NetworkFake.setGetResult(nil, nil, "Connection refused")

			local code, items, err = clientWithToken(TOKEN):getHighlights(CLIENT_BOOK_ID)

			assert.is_nil(code)
			assert.is_nil(items)
			assert.are.equal("Connection refused", err)
		end)

		it("names a network failure that came with no message", function()
			NetworkFake.setGetResult(nil, nil, nil)

			local _, _, err = clientWithToken(TOKEN):getHighlights(CLIENT_BOOK_ID)

			assert.are.equal("Network error", err)
		end)

		it("does not reach the network when authentication fails", function()
			local _, _, err = clientWithToken(nil, "Invalid credentials"):getHighlights(CLIENT_BOOK_ID)

			assert.are.equal("Invalid credentials", err)
			assert.are.same({}, NetworkFake.requested)
		end)

		it("names an authentication failure that came with no message", function()
			local _, _, err = clientWithToken(nil, nil):getHighlights(CLIENT_BOOK_ID)

			assert.are.equal("Authentication failed", err)
		end)
	end)
end)
