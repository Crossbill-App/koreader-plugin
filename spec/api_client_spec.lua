local json = require("json")
local AuthFailed = require("modules/auth_failed")
local UpgradeRequired = require("modules/upgrade_required")
local FakeNetwork = require("fake_network")

-- `modules/network` is the plugin's own module, not one of KOReader's, so it
-- cannot be shadowed by a file in spec/support: `crossbill.koplugin` comes first
-- on the path. It is also the one module that must not run under test, being
-- the one that opens sockets. Seeding the package cache before requiring the
-- api client binds the client to this fake for the whole run; the real module is
-- put back afterwards so nothing else sees the fake.
local network = FakeNetwork:new()

local real_network = package.loaded["modules/network"]
package.loaded["modules/network"] = network
local ApiClient = require("modules/api_client")
package.loaded["modules/network"] = real_network

local BASE_URL = "https://crossbill.example"
local CLIENT_BOOK_ID = "b9c1"
local TOKEN = "access-abc"

--- Build an auth stand-in that hands out the given tokens, one per attempt
-- The last token stands for every attempt after it, and `false` stands for an
-- attempt that authenticates nobody. The stand-in counts what it was asked for,
-- so a test can tell a retry from a call that never happened.
-- @param tokens table Array of tokens, or `false` entries for failure
-- @param auth_err string|nil The error a failed attempt reports
-- @return table The auth stand-in
local function authWithTokens(tokens, auth_err)
	return {
		tokens_handed_out = 0,
		cleared = 0,
		getValidToken = function(self)
			self.tokens_handed_out = self.tokens_handed_out + 1
			local token = tokens[math.min(self.tokens_handed_out, #tokens)]
			if not token then
				return nil, auth_err
			end
			return token
		end,
		clearTokens = function(self)
			self.cleared = self.cleared + 1
		end,
	}
end

--- Build an ApiClient on the given auth
-- @param auth table The auth stand-in
-- @return table The ApiClient instance
local function clientWithAuth(auth)
	return ApiClient:new({
		getApiUrl = function()
			return BASE_URL .. "/api/v1"
		end,
	}, auth)
end

--- Build an ApiClient whose auth hands out the given token
-- @param token string|nil The token, or nil to fail authentication
-- @param auth_err string|nil The authentication error
-- @return table The ApiClient instance
local function clientWithToken(token, auth_err)
	return clientWithAuth(authWithTokens({ token or false }, auth_err))
end

describe("ApiClient", function()
	before_each(function()
		network.reset()
	end)

	describe("uploadHighlights", function()
		local A_HIGHLIGHT = { text = "Fear is the mind-killer" }

		--- Upload with a successful server answer and hand back the payload sent
		-- @param highlights table The highlights to upload
		-- @param removed_ids table|nil The ids to remove
		-- @return table The payload the client built
		local function payloadFor(highlights, removed_ids)
			network.setPostResult(200, { highlights_created = 0, highlights_skipped = 0, highlights_removed = 0 })
			clientWithToken(TOKEN):uploadHighlights(CLIENT_BOOK_ID, highlights, "device-1", removed_ids)
			return network.posted_json[1].data
		end

		it("sends the highlights, the book and the device", function()
			local payload = payloadFor({ A_HIGHLIGHT })

			assert.are.equal(BASE_URL .. "/api/v1/highlights/sync", network.posted_json[1].url)
			assert.are.equal(TOKEN, network.posted_json[1].token)
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
			network.setPostResult(200, { highlights_created = 2, highlights_skipped = 1, highlights_removed = 3 })

			local code, response, err = clientWithToken(TOKEN):uploadHighlights(
				CLIENT_BOOK_ID,
				{ A_HIGHLIGHT },
				nil,
				{ 7 }
			)

			assert.are.equal(200, code)
			assert.are.equal(3, response.highlights_removed)
			assert.is_nil(err)
		end)

		it("reports a failed upload with its status", function()
			network.setPostResult(500, nil)

			local code, response, err = clientWithToken(TOKEN):uploadHighlights(
				CLIENT_BOOK_ID,
				{ A_HIGHLIGHT },
				nil,
				{ 7 }
			)

			assert.are.equal(500, code)
			assert.is_nil(response)
			assert.are.equal("Upload failed: 500", err)
		end)

		it("does not reach the network when authentication fails", function()
			local code, _, err = clientWithToken(nil, "Invalid credentials"):uploadHighlights(
				CLIENT_BOOK_ID,
				{ A_HIGHLIGHT },
				nil,
				{ 7 }
			)

			-- Nothing answered, so there is no status to report.
			assert.is_nil(code)
			assert.are.equal("Invalid credentials", err)
			assert.are.same({}, network.posted_json)
		end)
	end)

	describe("uploadReadingSessions", function()
		it("sends the sessions to the sync endpoint in the API's own shape", function()
			network.setPostResult(200, { created_count = 1, skipped_duplicate_count = 0 })

			local code = clientWithToken(TOKEN):uploadReadingSessions(CLIENT_BOOK_ID, {
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

			assert.are.equal(200, code)
			assert.are.equal(BASE_URL .. "/api/v1/reading_sessions/sync", network.posted_json[1].url)
			local payload = network.posted_json[1].data
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
			network.setGetResult(200, { items = {} })

			clientWithToken(TOKEN):getHighlights(CLIENT_BOOK_ID)

			assert.are.equal(
				BASE_URL .. "/api/v1/ereader/books/" .. CLIENT_BOOK_ID .. "/highlights",
				network.requested[1].url
			)
			assert.are.equal(TOKEN, network.requested[1].token)
		end)

		it("returns the status and the items on success", function()
			network.setGetResult(200, { items = { { text = "one" }, { text = "two" } } })

			local code, items, err = clientWithToken(TOKEN):getHighlights(CLIENT_BOOK_ID)

			assert.are.equal(200, code)
			assert.are.equal(2, #items)
			assert.are.equal("one", items[1].text)
			assert.is_nil(err)
		end)

		it("turns the decoder's empty-array marker into a plain table", function()
			-- A book with no highlights decodes to the marker rather than to a
			-- table, which the caller would otherwise be handed and iterate.
			network.setGetResult(200, { items = json.EMPTY_ARRAY })

			local code, items = clientWithToken(TOKEN):getHighlights(CLIENT_BOOK_ID)

			assert.are.equal(200, code)
			assert.are.same({}, items)
			assert.are_not.equal(json.EMPTY_ARRAY, items)
		end)

		it("returns an empty list when the response carries no items at all", function()
			network.setGetResult(200, {})

			local code, items = clientWithToken(TOKEN):getHighlights(CLIENT_BOOK_ID)

			assert.are.equal(200, code)
			assert.are.same({}, items)
		end)

		it("copies the items rather than handing back the response's own table", function()
			local body = { items = { { text = "one" } } }
			network.setGetResult(200, body)

			local _, items = clientWithToken(TOKEN):getHighlights(CLIENT_BOOK_ID)

			assert.are_not.equal(body.items, items)
		end)

		it("reports a book the server does not know without an error", function()
			-- 404 is an answer, not a failure: the book has never been synced.
			network.setGetResult(404, nil)

			local code, items, err = clientWithToken(TOKEN):getHighlights(CLIENT_BOOK_ID)

			assert.are.equal(404, code)
			assert.is_nil(items)
			assert.is_nil(err)
		end)

		it("reports a server failure with its status", function()
			network.setGetResult(500, nil)

			local code, items, err = clientWithToken(TOKEN):getHighlights(CLIENT_BOOK_ID)

			assert.are.equal(500, code)
			assert.is_nil(items)
			assert.are.equal("Fetch failed: 500", err)
		end)

		it("reads a 200 with no body at all as a book with no highlights", function()
			-- The status is the verdict, and an endpoint that answers one with no
			-- body is answering that there is nothing to send.
			network.setGetResult(200, nil)

			local code, items, err = clientWithToken(TOKEN):getHighlights(CLIENT_BOOK_ID)

			assert.are.equal(200, code)
			assert.are.same({}, items)
			assert.is_nil(err)
		end)

		it("passes a network error straight back", function()
			network.setGetResult(nil, nil, "Connection refused")

			local code, items, err = clientWithToken(TOKEN):getHighlights(CLIENT_BOOK_ID)

			assert.is_nil(code)
			assert.is_nil(items)
			assert.are.equal("Connection refused", err)
		end)

		it("names a network failure that came with no message", function()
			network.setGetResult(nil, nil, nil)

			local _, _, err = clientWithToken(TOKEN):getHighlights(CLIENT_BOOK_ID)

			assert.are.equal("Network error", err)
		end)

		it("does not reach the network when authentication fails", function()
			local _, _, err = clientWithToken(nil, "Invalid credentials"):getHighlights(CLIENT_BOOK_ID)

			assert.are.equal("Invalid credentials", err)
			assert.are.same({}, network.requested)
		end)

		it("names an authentication failure that came with no message", function()
			local _, _, err = clientWithToken(nil, nil):getHighlights(CLIENT_BOOK_ID)

			-- Still typed, so a caller can still tell what kind of failure it was.
			assert.is_true(AuthFailed.is(err))
			assert.are.equal("Authentication failed", AuthFailed.message(err))
		end)
	end)

	describe("uploadEpub", function()
		it("reports a successful upload with the status and nothing else", function()
			-- These endpoints answer with no body at all, so the status is the
			-- whole answer.
			network.setMultipartResult(200, "")

			local code, response, err = clientWithToken(TOKEN):uploadEpub(CLIENT_BOOK_ID, "epub-bytes", "a.epub")

			assert.are.equal(200, code)
			assert.is_nil(response)
			assert.is_nil(err)
			assert.are.equal(BASE_URL .. "/api/v1/ereader/books/" .. CLIENT_BOOK_ID .. "/epub", network.uploaded[1].url)
		end)

		it("reports a rejected upload with its status", function()
			network.setMultipartResult(500, "")

			local code, response, err = clientWithToken(TOKEN):uploadEpub(CLIENT_BOOK_ID, "epub-bytes", "a.epub")

			assert.are.equal(500, code)
			assert.is_nil(response)
			assert.are.equal("Upload failed: 500", err)
		end)
	end)

	describe("a 200 the server sent no body with", function()
		-- The status is the whole verdict: a caller that goes by `code == 200`
		-- must not be handed a success and an error at the same time. What the
		-- missing body cost is the caller's to say, since only it knows whether it
		-- needed one.

		it("is a success without data on a fetch", function()
			network.setGetResult(200, nil)

			local code, data, err = clientWithToken(TOKEN):getBookMetadata(CLIENT_BOOK_ID)

			assert.are.equal(200, code)
			assert.is_nil(data)
			assert.is_nil(err)
		end)

		it("is a success without data on a post", function()
			network.setPostResult(200, nil)

			local code, data, err = clientWithToken(TOKEN):createBook({ client_book_id = CLIENT_BOOK_ID })

			assert.are.equal(200, code)
			assert.is_nil(data)
			assert.is_nil(err)
		end)
	end)

	describe("a 200 whose body would not decode", function()
		-- Nothing about that answer is usable, so it is reported the way a request
		-- that never arrived is: no status, and a message saying which call it was.

		it("is reported without a status on a fetch", function()
			network.setGetResult(200, nil, "Invalid JSON response")

			local code, data, err = clientWithToken(TOKEN):getBookMetadata(CLIENT_BOOK_ID)

			assert.is_nil(code)
			assert.is_nil(data)
			assert.are.equal("book metadata: the server answered 200 with a body that would not decode", err)
		end)

		it("is reported without a status on a post", function()
			network.setPostResult(200, nil, "Invalid JSON response")

			local code, data, err = clientWithToken(TOKEN):uploadHighlights(CLIENT_BOOK_ID, {}, nil, { 7 })

			assert.is_nil(code)
			assert.is_nil(data)
			assert.are.equal("highlights: the server answered 200 with a body that would not decode", err)
		end)
	end)

	describe("an authentication failure on the way out", function()
		-- The plugin picks the dialog a reader sees by the error's type, so the
		-- one Auth built has to reach the caller as itself rather than as its
		-- text; matching on the wording is exactly what used to be broken.

		--- Build a client whose auth fails with a typed error
		-- @return table The ApiClient instance
		local function clientRefusedByAuth()
			return clientWithToken(nil, AuthFailed.new("Login failed: 401"))
		end

		it("reaches the caller of a fetch intact", function()
			local code, data, err = clientRefusedByAuth():getBookMetadata(CLIENT_BOOK_ID)

			assert.is_nil(code)
			assert.is_nil(data)
			assert.is_true(AuthFailed.is(err))
			assert.are.equal("Login failed: 401", AuthFailed.message(err))
		end)

		it("reaches the caller of an upload intact", function()
			local code, data, err = clientRefusedByAuth():uploadHighlights(CLIENT_BOOK_ID, {}, nil, nil)

			assert.is_nil(code)
			assert.is_nil(data)
			assert.is_true(AuthFailed.is(err))
			assert.are.equal("Login failed: 401", AuthFailed.message(err))
		end)

		it("reaches the caller of an EPUB upload intact", function()
			local code, _, err = clientRefusedByAuth():uploadEpub(CLIENT_BOOK_ID, "epub-bytes", "a.epub")

			assert.is_nil(code)
			assert.is_true(AuthFailed.is(err))
			assert.are.same({}, network.uploaded)
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

		--- Make a call the server refuses, handing back what it raised
		-- The refusal is raised rather than returned, so no caller has to
		-- remember to look for it in an error slot.
		-- @param fn function The call to make
		-- @return any The error the call raised
		local function refusalRaisedBy(fn)
			local ok, err = pcall(fn)

			assert.is_false(ok)
			return err
		end

		it("raises the refusal rather than answering a fetch with a status", function()
			network.setGetResult(426, REFUSAL)
			local client = clientWithToken(TOKEN)

			assertRefusal(refusalRaisedBy(function()
				return client:getHighlights(CLIENT_BOOK_ID)
			end))
		end)

		it("raises it out of a refused highlight upload the same way", function()
			network.setPostResult(426, REFUSAL)
			local client = clientWithToken(TOKEN)

			assertRefusal(refusalRaisedBy(function()
				return client:uploadHighlights(CLIENT_BOOK_ID, {}, nil, { 7 })
			end))
		end)

		it("raises it out of a refused session upload the same way", function()
			network.setPostResult(426, REFUSAL)
			local client = clientWithToken(TOKEN)

			assertRefusal(refusalRaisedBy(function()
				return client:uploadReadingSessions(CLIENT_BOOK_ID, {})
			end))
		end)

		it("raises it out of a refused book creation the same way", function()
			network.setPostResult(426, REFUSAL)
			local client = clientWithToken(TOKEN)

			assertRefusal(refusalRaisedBy(function()
				return client:createBook({ client_book_id = CLIENT_BOOK_ID })
			end))
		end)

		it("raises it out of a refused EPUB upload the same way", function()
			-- The multipart helper hands back an undecoded body, so this path
			-- reads the refusal's detail for itself.
			network.setMultipartResult(426, '{"detail": {}}')
			stub(json, "decode", REFUSAL)
			local client = clientWithToken(TOKEN)

			local err = refusalRaisedBy(function()
				return client:uploadEpub(CLIENT_BOOK_ID, "epub-bytes", "a.epub")
			end)

			json.decode:revert()
			assertRefusal(err)
		end)

		it("still raises a refusal whose body could not be read", function()
			network.setGetResult(426, nil, "Invalid JSON response")
			local client = clientWithToken(TOKEN)

			local err = refusalRaisedBy(function()
				return client:getHighlights(CLIENT_BOOK_ID)
			end)

			assert.is_true(UpgradeRequired.is(err))
			assert.is_nil(err.min_supported_version)
			assert.is_nil(err.received_version)
			assert.is_nil(err.update_url)
		end)

		it("still raises an EPUB refusal whose body could not be read", function()
			network.setMultipartResult(426, "<html>Upgrade required</html>")
			local client = clientWithToken(TOKEN)

			local err = refusalRaisedBy(function()
				return client:uploadEpub(CLIENT_BOOK_ID, "epub-bytes", "a.epub")
			end)

			assert.is_true(UpgradeRequired.is(err))
			assert.is_nil(err.min_supported_version)
		end)

		it("lets a refusal met while authenticating out of the call", function()
			-- The login carries the version header too, so a plugin the server will
			-- not serve is refused while fetching a token rather than while using
			-- one. Auth raises it, and nothing between there and here turns it back
			-- into a status.
			local client = clientWithAuth({
				getValidToken = function()
					error(UpgradeRequired.new(REFUSAL), 0)
				end,
			})

			assertRefusal(refusalRaisedBy(function()
				return client:getBookMetadata(CLIENT_BOOK_ID)
			end))
			assert.are.same({}, network.requested)
		end)

		it("leaves every other failure as the message it was", function()
			network.setPostResult(500, nil)

			local _, _, err = clientWithToken(TOKEN):uploadHighlights(CLIENT_BOOK_ID, {}, nil, { 7 })

			assert.are.equal("Upload failed: 500", err)
		end)
	end)

	describe("a token the server refuses", function()
		-- A token revoked before the expiry the plugin recorded stays cached, so
		-- without a retry every later call fails the same way until it expires.

		it("logs in again and repeats a fetch the server turned away", function()
			local auth = authWithTokens({ "revoked", "fresh" })
			network.setGetResults({ 401 }, { 200, { items = { { text = "one" } } } })

			local code, items, err = clientWithAuth(auth):getHighlights(CLIENT_BOOK_ID)

			assert.are.equal(200, code)
			assert.are.equal(1, #items)
			assert.is_nil(err)
			assert.are.equal(1, auth.cleared)
			assert.are.equal(2, #network.requested)
			assert.are.equal("revoked", network.requested[1].token)
			assert.are.equal("fresh", network.requested[2].token)
		end)

		it("logs in again and repeats an upload the server turned away", function()
			local auth = authWithTokens({ "revoked", "fresh" })
			network.setPostResults({ 401 }, { 200, { highlights_created = 1 } })

			local code, response, err = clientWithAuth(auth):uploadHighlights(CLIENT_BOOK_ID, {}, nil, { 7 })

			assert.are.equal(200, code)
			assert.are.equal(1, response.highlights_created)
			assert.is_nil(err)
			assert.are.equal(1, auth.cleared)
			assert.are.equal(2, #network.posted_json)
			assert.are.equal("revoked", network.posted_json[1].token)
			assert.are.equal("fresh", network.posted_json[2].token)
		end)

		it("logs in again and repeats an EPUB upload the server turned away", function()
			local auth = authWithTokens({ "revoked", "fresh" })
			network.setMultipartResults({ 401 }, { 200 })

			local code, _, err = clientWithAuth(auth):uploadEpub(CLIENT_BOOK_ID, "epub-bytes", "a.epub")

			assert.are.equal(200, code)
			assert.is_nil(err)
			assert.are.equal(1, auth.cleared)
			assert.are.equal(2, #network.uploaded)
			assert.are.equal("fresh", network.uploaded[2].token)
		end)

		it("sends the retry with the payload the first attempt carried", function()
			network.setPostResults({ 401 }, { 200, { created_count = 0 } })

			clientWithAuth(authWithTokens({ "revoked", "fresh" })):uploadHighlights(
				CLIENT_BOOK_ID,
				{ { text = "Fear is the mind-killer" } },
				"device-1",
				{ 7 }
			)

			assert.are.same(network.posted_json[1].data, network.posted_json[2].data)
			assert.are.equal(CLIENT_BOOK_ID, network.posted_json[2].data.client_book_id)
		end)

		it("reports a second refusal rather than trying a third time", function()
			local auth = authWithTokens({ "revoked", "also-revoked" })
			network.setGetResult(401)

			local code, items, err = clientWithAuth(auth):getHighlights(CLIENT_BOOK_ID)

			assert.are.equal(401, code)
			assert.is_nil(items)
			assert.are.equal("Fetch failed: 401", err)
			assert.are.equal(1, auth.cleared)
			assert.are.equal(2, #network.requested)
		end)

		it("reports a second refusal of an upload the same way", function()
			local auth = authWithTokens({ "revoked", "also-revoked" })
			network.setPostResult(401)

			local code, _, err = clientWithAuth(auth):uploadHighlights(CLIENT_BOOK_ID, {}, nil, { 7 })

			assert.are.equal(401, code)
			assert.are.equal("Upload failed: 401", err)
			assert.are.equal(2, #network.posted_json)
		end)

		it("gives up when logging in again fails", function()
			local auth = authWithTokens({ "revoked", false }, "Invalid credentials")
			network.setGetResult(401)

			local code, items, err = clientWithAuth(auth):getHighlights(CLIENT_BOOK_ID)

			assert.is_nil(code)
			assert.is_nil(items)
			assert.are.equal("Invalid credentials", err)
			assert.are.equal(1, #network.requested)
		end)

		it("leaves every other failure to be reported without a second attempt", function()
			local auth = authWithTokens({ TOKEN })
			network.setGetResult(500)

			clientWithAuth(auth):getHighlights(CLIENT_BOOK_ID)

			assert.are.equal(0, auth.cleared)
			assert.are.equal(1, #network.requested)
		end)
	end)
end)
