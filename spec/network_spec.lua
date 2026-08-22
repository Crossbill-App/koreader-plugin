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

local SocketUtilFake = {}

--- Reset the socket timeout, which is a no-op without sockets
function SocketUtilFake:reset_timeout() end

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
		JsonFake.encoded = {}
		JsonFake.decoded = nil
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
end)
