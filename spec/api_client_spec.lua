local json = require("json")
local UpgradeRequired = require("modules/upgrade_required")

-- `modules/network` is the plugin's own module, not one of KOReader's, so it
-- cannot be shadowed by a file in spec/support: `crossbill.koplugin` comes first
-- on the path. It is also the one module that must not run under test, being
-- the one that opens sockets. Seeding the package cache before requiring the
-- api client binds the client to this fake for the whole run; the real module is
-- put back afterwards so nothing else sees the fake.
local NetworkFake = {
	get_result = { nil, nil, nil },
	post_result = { nil, nil, nil },
	multipart_result = { nil, nil, nil },
	requested = {},
	posted = {},
	uploaded = {},
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

--- Answer `postJson` with whatever the current test has queued
-- @param url string The URL being posted to
-- @param data table The payload the client built
-- @param token string|nil The bearer token
-- @return number|nil, table|nil, string|nil The queued status, body and error
function NetworkFake.postJson(url, data, token)
	table.insert(NetworkFake.posted, { url = url, data = data, token = token })
	return NetworkFake.post_result[1], NetworkFake.post_result[2], NetworkFake.post_result[3]
end

--- Queue the tuple the next `postJson` should return
-- @param code number|nil The HTTP status
-- @param body table|nil The decoded response body
-- @param err string|nil The error message
function NetworkFake.setPostResult(code, body, err)
	NetworkFake.post_result = { code, body, err }
end

--- Answer `postMultipart` with whatever the current test has queued
-- Answers with the body undecoded, as the real module does.
-- @param url string The URL being posted to
-- @param files table The files the client built
-- @param token string|nil The bearer token
-- @return number|nil, string|nil, string|nil The queued status, body and error
function NetworkFake.postMultipart(url, files, token)
	table.insert(NetworkFake.uploaded, { url = url, files = files, token = token })
	return NetworkFake.multipart_result[1], NetworkFake.multipart_result[2], NetworkFake.multipart_result[3]
end

--- Queue the tuple the next `postMultipart` should return
-- @param code number|nil The HTTP status
-- @param body string|nil The undecoded response body
-- @param err string|nil The error message
function NetworkFake.setMultipartResult(code, body, err)
	NetworkFake.multipart_result = { code, body, err }
end

--- Forget the requests made and the queued answers
function NetworkFake.reset()
	NetworkFake.get_result = { nil, nil, nil }
	NetworkFake.post_result = { nil, nil, nil }
	NetworkFake.multipart_result = { nil, nil, nil }
	NetworkFake.requested = {}
	NetworkFake.posted = {}
	NetworkFake.uploaded = {}
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

	describe("uploadHighlights", function()
		local A_HIGHLIGHT = { text = "Fear is the mind-killer" }

		--- Upload with a successful server answer and hand back the payload sent
		-- @param highlights table The highlights to upload
		-- @param removed_ids table|nil The ids to remove
		-- @return table The payload the client built
		local function payloadFor(highlights, removed_ids)
			NetworkFake.setPostResult(200, { highlights_created = 0, highlights_skipped = 0, highlights_removed = 0 })
			clientWithToken(TOKEN):uploadHighlights(CLIENT_BOOK_ID, highlights, "device-1", removed_ids)
			return NetworkFake.posted[1].data
		end

		it("sends the highlights, the book and the device", function()
			local payload = payloadFor({ A_HIGHLIGHT })

			assert.are.equal(BASE_URL .. "/api/v1/highlights/sync", NetworkFake.posted[1].url)
			assert.are.equal(TOKEN, NetworkFake.posted[1].token)
			assert.are.equal(CLIENT_BOOK_ID, payload.client_book_id)
			assert.are.equal("device-1", payload.device_id)
			assert.are.same({ A_HIGHLIGHT }, payload.highlights)
		end)

		it("sends the ids deleted on the device alongside them", function()
			local payload = payloadFor({ A_HIGHLIGHT }, { 7, 12 })

			assert.are.same({ 7, 12 }, payload.removed_ids)
		end)

		it("leaves the removals out when there are none", function()
			-- Exactly the payload every older plugin sent, so nothing changes
			-- for a sync that deleted nothing.
			assert.is_nil(payloadFor({ A_HIGHLIGHT }, {}).removed_ids)
			assert.is_nil(payloadFor({ A_HIGHLIGHT }, nil).removed_ids)
		end)

		it("sends an empty highlight set as an array, not as an object", function()
			-- A removal-only push carries no highlights, and a bare Lua table
			-- would reach the server as `{}` where it expects a list.
			local payload = payloadFor({}, { 7 })

			assert.are.equal(json.EMPTY_ARRAY, payload.highlights)
		end)

		it("returns the counts the server reported", function()
			NetworkFake.setPostResult(200, { highlights_created = 2, highlights_skipped = 1, highlights_removed = 3 })

			local ok, response, err = clientWithToken(TOKEN):uploadHighlights(
				CLIENT_BOOK_ID,
				{ A_HIGHLIGHT },
				nil,
				{ 7 }
			)

			assert.is_true(ok)
			assert.are.equal(3, response.highlights_removed)
			assert.is_nil(err)
		end)

		it("reports a failed upload with its status", function()
			NetworkFake.setPostResult(500, nil)

			local ok, response, err = clientWithToken(TOKEN):uploadHighlights(
				CLIENT_BOOK_ID,
				{ A_HIGHLIGHT },
				nil,
				{ 7 }
			)

			assert.is_false(ok)
			assert.is_nil(response)
			assert.are.equal("Upload failed: 500", err)
		end)

		it("does not reach the network when authentication fails", function()
			local ok, _, err = clientWithToken(nil, "Invalid credentials"):uploadHighlights(
				CLIENT_BOOK_ID,
				{ A_HIGHLIGHT },
				nil,
				{ 7 }
			)

			assert.is_false(ok)
			assert.are.equal("Invalid credentials", err)
			assert.are.same({}, NetworkFake.posted)
		end)
	end)

	describe("uploadReadingSessions", function()
		it("sends the sessions to the sync endpoint in the API's own shape", function()
			NetworkFake.setPostResult(200, { created_count = 1, skipped_duplicate_count = 0 })

			local ok = clientWithToken(TOKEN):uploadReadingSessions(CLIENT_BOOK_ID, {
				{
					start_time = 1700000000,
					end_time = 1700003600,
					device_id = "device-1",
					start_page = 10,
					end_page = 15,
					position_type = "xpointer",
					start_position = "/body/div[1]/p[1]",
					end_position = "/body/div[1]/p[50]",
				},
			})

			assert.is_true(ok)
			assert.are.equal(BASE_URL .. "/api/v1/reading_sessions/sync", NetworkFake.posted[1].url)
			local payload = NetworkFake.posted[1].data
			assert.are.equal(CLIENT_BOOK_ID, payload.client_book_id)
			assert.are.same({
				{
					start_time = "2023-11-14T22:13:20Z",
					end_time = "2023-11-14T23:13:20Z",
					device_id = "device-1",
					start_page = 10,
					end_page = 15,
					start_xpoint = "/body/div[1]/p[1]",
					end_xpoint = "/body/div[1]/p[50]",
				},
			}, payload.sessions)
		end)
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

	describe("the server that turns this plugin away as too old", function()
		local REFUSAL = {
			detail = {
				code = "client_upgrade_required",
				client = "koreader-plugin",
				min_supported_version = "0.13.0",
				received_version = "0.12.0",
				update_url = "https://github.com/Crossbill-App/koreader-plugin",
			},
		}

		--- Assert that an error is the refusal, carrying what the server said
		-- @param err any The error the client reported
		local function assertRefusal(err)
			assert.is_true(UpgradeRequired.is(err))
			assert.are.equal("0.13.0", err.min_supported_version)
			assert.are.equal("0.12.0", err.received_version)
			assert.are.equal("https://github.com/Crossbill-App/koreader-plugin", err.update_url)
		end

		it("reports a refused fetch as the refusal rather than as a status", function()
			NetworkFake.setGetResult(426, REFUSAL)

			local code, items, err = clientWithToken(TOKEN):getHighlights(CLIENT_BOOK_ID)

			assert.are.equal(426, code)
			assert.is_nil(items)
			assertRefusal(err)
		end)

		it("reports a refused highlight upload the same way", function()
			NetworkFake.setPostResult(426, REFUSAL)

			local ok, _, err = clientWithToken(TOKEN):uploadHighlights(CLIENT_BOOK_ID, {}, nil, { 7 })

			assert.is_false(ok)
			assertRefusal(err)
		end)

		it("reports a refused session upload the same way", function()
			NetworkFake.setPostResult(426, REFUSAL)

			local ok, _, err = clientWithToken(TOKEN):uploadReadingSessions(CLIENT_BOOK_ID, {})

			assert.is_false(ok)
			assertRefusal(err)
		end)

		it("reports a refused book creation the same way", function()
			NetworkFake.setPostResult(426, REFUSAL)

			local ok, _, err = clientWithToken(TOKEN):createBook({ client_book_id = CLIENT_BOOK_ID })

			assert.is_false(ok)
			assertRefusal(err)
		end)

		it("reports a refused EPUB upload the same way", function()
			-- The multipart helper hands back an undecoded body, so this path
			-- reads the refusal's detail for itself.
			NetworkFake.setMultipartResult(426, '{"detail": {}}')
			stub(json, "decode", REFUSAL)

			local ok, _, err = clientWithToken(TOKEN):uploadEpub(CLIENT_BOOK_ID, "epub-bytes", "a.epub")

			json.decode:revert()
			assert.is_false(ok)
			assertRefusal(err)
		end)

		it("still reports a refusal whose body could not be read", function()
			NetworkFake.setGetResult(426, nil, "Invalid JSON response")

			local _, _, err = clientWithToken(TOKEN):getHighlights(CLIENT_BOOK_ID)

			assert.is_true(UpgradeRequired.is(err))
			assert.is_nil(err.min_supported_version)
			assert.is_nil(err.received_version)
			assert.is_nil(err.update_url)
		end)

		it("still reports an EPUB refusal whose body could not be read", function()
			NetworkFake.setMultipartResult(426, "<html>Upgrade required</html>")

			local ok, _, err = clientWithToken(TOKEN):uploadEpub(CLIENT_BOOK_ID, "epub-bytes", "a.epub")

			assert.is_false(ok)
			assert.is_true(UpgradeRequired.is(err))
			assert.is_nil(err.min_supported_version)
		end)

		it("leaves every other failure as the message it was", function()
			NetworkFake.setPostResult(500, nil)

			local _, _, err = clientWithToken(TOKEN):uploadHighlights(CLIENT_BOOK_ID, {}, nil, { 7 })

			assert.are.equal("Upload failed: 500", err)
		end)
	end)
end)
