--[[
The rest of the suite fakes `modules/network` to keep sockets out of the run
(see spec/support/koreader/README.md). This spec loads the real module instead,
with LuaSocket, the JSON library and KOReader's network manager faked underneath
it, so the client header every request carries is observable without reaching
the wire.
]]

local meta = require("_meta")

-- Stands in for both `socket.http` and `ssl.https`, so a request cannot pick
-- the scheme that is not being watched.
local HttpFake = { requests = {}, status = 200, body = "" }

--- Record a request and answer it the way LuaSocket does
-- @param request table The request table the module built
-- @return number, number, table, string LuaSocket's 1, status, headers, line
function HttpFake.request(request)
	table.insert(HttpFake.requests, request)
	if HttpFake.fails_with then
		-- How LuaSocket reports a request that never completed: no result, and
		-- the message where a status would otherwise be.
		return nil, HttpFake.fails_with
	end
	if HttpFake.body ~= "" then
		request.sink(HttpFake.body)
	end
	return 1, HttpFake.status, {}, "HTTP/1.1 " .. tostring(HttpFake.status)
end

local SocketFake = {}

--- Drop the first `n` of the following values, as LuaSocket's `skip` does
-- @param n number How many values to drop
-- @return ... The remaining values
function SocketFake.skip(n, ...)
	return select(n + 1, ...)
end

local Ltn12Fake = {
	sink = {
		--- Collect the response chunks into a table
		-- @param collected table The table to append to
		-- @return function The sink
		table = function(collected)
			return function(chunk)
				if chunk then
					table.insert(collected, chunk)
				end
				return 1
			end
		end,
	},
	source = {
		--- Serve a string as a source
		-- @param body string The body to serve
		-- @return function The source
		string = function(body)
			return function()
				return body
			end
		end,
	},
}

-- Records the timeouts each request asked for, and hands out a sink that
-- collects chunks the way the real one does. The presets carry the real
-- module's values so a spec can assert on them by name rather than by number.
local SocketUtilFake = {
	FILE_BLOCK_TIMEOUT = 15,
	FILE_TOTAL_TIMEOUT = 60,
	LARGE_BLOCK_TIMEOUT = 10,
	LARGE_TOTAL_TIMEOUT = 30,
	timeouts = {},
	resets = 0,
}

--- Remember the timeouts a request set
-- @param block_timeout number How long the request may stall
-- @param total_timeout number How long it may take start to finish
function SocketUtilFake:set_timeout(block_timeout, total_timeout)
	table.insert(self.timeouts, { block = block_timeout, total = total_timeout })
end

--- Count the resets, which is how the spec knows one always follows a request
function SocketUtilFake:reset_timeout()
	self.resets = self.resets + 1
end

--- Collect chunks into a table, as the real sink does
-- @param collected table The table to append to
-- @return function The sink
function SocketUtilFake.table_sink(collected)
	return function(chunk)
		if chunk then
			table.insert(collected, chunk)
		end
		return 1
	end
end

--- The timeouts the most recent request asked for
-- @return table|nil The block and total
function SocketUtilFake.lastTimeout()
	return SocketUtilFake.timeouts[#SocketUtilFake.timeouts]
end

-- Only WiFi handling touches the manager, and no test here does.
local NetworkMgrFake = {}

-- The support stub decodes only the one literal `modules/api_client` needs, and
-- `postJson` has a payload to encode, so this spec brings its own.
local JsonFake = { encoded = {}, decoded = nil }

--- Encode a payload, remembering what it was handed
-- @param value table The payload
-- @return string A stand-in body
function JsonFake.encode(value)
	table.insert(JsonFake.encoded, value)
	return "{}"
end

--- Decode a body into whatever the current test queued
-- @return table|nil The queued value
function JsonFake.decode()
	return JsonFake.decoded
end

local FAKES = {
	["socket"] = SocketFake,
	["socket.http"] = HttpFake,
	["ssl.https"] = HttpFake,
	["ltn12"] = Ltn12Fake,
	["socketutil"] = SocketUtilFake,
	["ui/network/manager"] = NetworkMgrFake,
	["json"] = JsonFake,
}

-- Everything is put back after the load, the module included: no other spec
-- should end up with the copy bound to these fakes.
local saved = { ["modules/network"] = package.loaded["modules/network"] }
for name, fake in pairs(FAKES) do
	saved[name] = package.loaded[name]
	package.loaded[name] = fake
end
local Network = require("modules/network")
package.loaded["modules/network"] = saved["modules/network"]
for name in pairs(FAKES) do
	package.loaded[name] = saved[name]
end

local URL = "https://crossbill.example/api/v1/ping"

describe("Network", function()
	before_each(function()
		HttpFake.requests = {}
		HttpFake.status = 200
		HttpFake.body = ""
		HttpFake.fails_with = nil
		JsonFake.encoded = {}
		JsonFake.decoded = nil
		SocketUtilFake.timeouts = {}
		SocketUtilFake.resets = 0
	end)

	--- The client header the request recorded last carried
	-- @return string|nil The header value
	local function clientHeader()
		local request = HttpFake.requests[#HttpFake.requests]
		return request and request.headers["X-Crossbill-Client"]
	end

	describe("the client it identifies itself as", function()
		it("names the plugin and the version _meta.lua declares", function()
			-- The server decides by what it reads here, so the version must be
			-- _meta.lua's own and not a copy that can drift from it.
			Network.request({ url = URL })

			assert.are.equal("koreader-plugin/" .. meta.version, clientHeader())
		end)

		it("says so on a request that brought no headers of its own", function()
			Network.request({ url = URL })

			assert.is_not_nil(clientHeader())
		end)

		it("says so alongside the headers a request did bring", function()
			Network.request({ url = URL, headers = { ["Accept"] = "application/json" } })

			assert.are.equal("application/json", HttpFake.requests[1].headers["Accept"])
			assert.is_not_nil(clientHeader())
		end)

		it("says so over plain HTTP as well as HTTPS", function()
			Network.request({ url = "http://crossbill.example/api/v1/ping" })

			assert.is_not_nil(clientHeader())
		end)

		it("says so on a JSON GET", function()
			Network.getJson(URL, "token-abc")

			assert.is_not_nil(clientHeader())
		end)

		it("says so on a JSON POST", function()
			Network.postJson(URL, { client_book_id = "b9c1" }, "token-abc")

			assert.is_not_nil(clientHeader())
		end)

		it("says so on a form POST, which is how the plugin logs in", function()
			Network.postForm(URL, { username = "reader", password = "hunter2" })

			assert.is_not_nil(clientHeader())
		end)

		it("says so on a multipart upload", function()
			Network.postMultipart(URL, { { name = "epub", filename = "a.epub", content_type = "x", data = "d" } })

			assert.is_not_nil(clientHeader())
		end)
	end)
	describe("the headers a JSON GET can be given", function()
		--- The headers the request recorded last carried
		-- @return table The header table
		local function headers()
			return HttpFake.requests[#HttpFake.requests].headers
		end

		it("adds what the caller asked for", function()
			-- GitHub refuses a request carrying no User-Agent, which is why
			-- getJson takes headers at all.
			Network.getJson(URL, nil, { ["User-Agent"] = "koreader-plugin/9.9.9" })

			assert.are.equal("koreader-plugin/9.9.9", headers()["User-Agent"])
		end)

		it("keeps the defaults a caller did not name", function()
			Network.getJson(URL, "token-abc", { ["User-Agent"] = "koreader-plugin/9.9.9" })

			assert.are.equal("application/json", headers()["Accept"])
			assert.are.equal("Bearer token-abc", headers()["Authorization"])
			assert.is_not_nil(clientHeader())
		end)

		it("lets a caller replace a default", function()
			Network.getJson(URL, nil, { ["Accept"] = "application/vnd.github+json" })

			assert.are.equal("application/vnd.github+json", headers()["Accept"])
		end)

		it("changes nothing when given none", function()
			Network.getJson(URL, "token-abc")

			assert.are.equal("application/json", headers()["Accept"])
		end)
	end)
	describe("the time it will wait", function()
		it("bounds every request, which LuaSocket by itself does not", function()
			-- KOReader's default total is -1, so without this a server that
			-- accepts a connection and then goes quiet holds the screen.
			Network.getJson(URL, "token-abc")

			assert.are.same(
				{ block = SocketUtilFake.FILE_BLOCK_TIMEOUT, total = SocketUtilFake.FILE_TOTAL_TIMEOUT },
				SocketUtilFake.lastTimeout()
			)
		end)

		it("puts the timeout back afterwards", function()
			Network.getJson(URL, "token-abc")

			assert.are.equal(1, SocketUtilFake.resets)
		end)

		it("puts it back even when the request failed", function()
			HttpFake.fails_with = "timeout"

			Network.getJson(URL, "token-abc")

			assert.are.equal(1, SocketUtilFake.resets)
		end)

		it("leaves an upload no total, since its size is the book's to decide", function()
			Network.postMultipart(URL, { { name = "epub", filename = "a.epub", content_type = "x", data = "d" } })

			local timeout = SocketUtilFake.lastTimeout()
			assert.are.equal(SocketUtilFake.FILE_BLOCK_TIMEOUT, timeout.block)
			assert.are.equal(-1, timeout.total)
		end)

		it("lets a caller ask for its own", function()
			Network.request({ url = URL, block_timeout = 3, total_timeout = 7 })

			assert.are.same({ block = 3, total = 7 }, SocketUtilFake.lastTimeout())
		end)
	end)

	describe("a request that never completed", function()
		it("reports the message as an error rather than as a status", function()
			-- LuaSocket returns `nil, message`, and the message sits where a
			-- status would. Read carelessly, a timeout looks like an HTTP code.
			HttpFake.fails_with = "timeout"

			local code, body, err = Network.request({ url = URL })

			assert.is_nil(code)
			assert.are.equal("", body)
			assert.are.equal("timeout", err)
		end)

		it("reaches the JSON callers as an error too", function()
			HttpFake.fails_with = "connection refused"

			local code, data, err = Network.getJson(URL)

			assert.is_nil(code)
			assert.is_nil(data)
			assert.are.equal("connection refused", err)
		end)
	end)

	describe("the size it will accept", function()
		it("accepts a response within the cap", function()
			HttpFake.body = string.rep("x", 100)

			local code, body = Network.request({ url = URL, max_bytes = 100 })

			assert.are.equal(200, code)
			assert.are.equal(100, #body)
		end)

		it("takes nothing from a response that outgrows the cap", function()
			HttpFake.body = string.rep("x", 101)

			local code, body = Network.request({ url = URL, max_bytes = 100 })

			assert.are.equal(200, code)
			assert.are.equal(0, #body)
		end)

		it("accepts anything when no cap was asked for", function()
			HttpFake.body = string.rep("x", 5000)

			local code, body = Network.request({ url = URL })

			assert.are.equal(200, code)
			assert.are.equal(5000, #body)
		end)
	end)
end)
