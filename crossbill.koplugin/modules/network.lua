--[[
Network Module for Crossbill Sync

Provides HTTP/HTTPS request utilities and WiFi management.
Abstracts away the complexity of KOReader's networking layer.
]]

local http = require("socket.http")
local https = require("ssl.https")
local ltn12 = require("ltn12")
local socketutil = require("socketutil")
local NetworkMgr = require("ui/network/manager")
local JSON = require("json")
local logger = require("logger")
local meta = require("_meta")

local Network = {}

-- How long a request may stall, and how long it may take start to finish.
-- KOReader leaves the total at -1 -- no limit at all -- so without these a
-- server that accepts a connection and then stops sending blocks the reader's
-- screen for as long as it likes. The file presets rather than the "large"
-- ones: the plugin's JSON bodies carry every highlight of a book, and aborting
-- a slow but working sync is worse than waiting a little longer for it.
Network.BLOCK_TIMEOUT = socketutil.FILE_BLOCK_TIMEOUT
Network.TOTAL_TIMEOUT = socketutil.FILE_TOTAL_TIMEOUT

-- A total of -1 means "no limit", which is what an upload whose size the plugin
-- does not control needs: the stall timeout still ends a dead connection.
Network.NO_TOTAL_TIMEOUT = -1

-- What a response that outgrew what the caller would accept is reported as
Network.TOO_LARGE_CODE = "response too large"

-- Identifies the plugin to the server, which refuses versions it no longer
-- supports. Read from `_meta.lua` rather than repeated here, so it cannot drift.
Network.CLIENT_HEADER = "X-Crossbill-Client"
Network.CLIENT_HEADER_VALUE = "koreader-plugin/" .. tostring(meta.version)

--- Decode a response body, keeping the status code the request came back with
-- An empty body is not an error: some endpoints answer with a status only.
-- @param code number The HTTP status code
-- @param response_text string|nil The raw response body
-- @return number HTTP status code
-- @return table|nil Parsed JSON response
-- @return string|nil Error message
local function decodedResponse(code, response_text)
	if not response_text or response_text == "" then
		return code, nil, nil
	end

	local ok, response_data = pcall(JSON.decode, response_text)
	if not ok then
		return code, nil, "Invalid JSON response"
	end

	return code, response_data, nil
end

-- Track whether we enabled WiFi (so we can turn it off after sync)
local wifi_enabled_by_us = false

--- URL encode a string for use in form-urlencoded data
-- @param str string The string to encode
-- @return string The URL-encoded string
function Network.urlEncode(str)
	if str then
		str = string.gsub(str, "\n", "\r\n")
		str = string.gsub(str, "([^%w _%%%-%.~])", function(c)
			return string.format("%%%02X", string.byte(c))
		end)
		str = string.gsub(str, " ", "+")
	end
	return str
end

--- Stop feeding a sink once the response outgrows what the caller accepts
-- A cap is only worth having before the bytes are in memory, so it is applied
-- as they arrive rather than checked afterwards.
-- @param sink function The sink to feed
-- @param max_bytes number|nil The most to accept, nil to accept anything
-- @return function The sink, wrapped when there is a cap
local function cappedSink(sink, max_bytes)
	if not max_bytes then
		return sink
	end

	local received = 0
	return function(chunk, err)
		if chunk then
			received = received + #chunk
			if received > max_bytes then
				return nil, Network.TOO_LARGE_CODE
			end
		end

		return sink(chunk, err)
	end
end

--- Make an HTTP/HTTPS request
-- @param options table Request options
--   - url: string (required) The URL to request
--   - method: string (default "GET") HTTP method
--   - headers: table HTTP headers
--   - body: string Request body
--   - block_timeout: number How long the request may stall
--   - total_timeout: number How long it may take start to finish, -1 for no limit
--   - max_bytes: number The largest response to accept
-- @return number|nil HTTP status code
-- @return string Response body
-- @return string|nil Error message
function Network.request(options)
	local url = options.url
	local method = options.method or "GET"
	local headers = options.headers or {}
	local body = options.body

	-- Set content length header if body is provided
	if body and not headers["Content-Length"] then
		headers["Content-Length"] = tostring(#body)
	end

	-- Every call passes through here, so no call site can forget it.
	headers[Network.CLIENT_HEADER] = Network.CLIENT_HEADER_VALUE

	-- Before the sink is built, not after: `socketutil.table_sink` reads the
	-- total it has to honour at the moment it is created.
	socketutil:set_timeout(
		options.block_timeout or Network.BLOCK_TIMEOUT,
		options.total_timeout or Network.TOTAL_TIMEOUT
	)

	local response_body = {}
	local request = {
		url = url,
		method = method,
		headers = headers,
		-- socketutil's sink rather than ltn12's: the total timeout is only
		-- enforced by the sink, so ltn12's would leave it decorative.
		sink = cappedSink(socketutil.table_sink(response_body), options.max_bytes),
	}

	if body then
		request.source = ltn12.source.string(body)
	end

	-- Use HTTP or HTTPS based on URL scheme
	local result, code_or_err
	if url:match("^https://") then
		logger.dbg("Crossbill Network: Using HTTPS for", url)
		result, code_or_err = https.request(request)
	else
		logger.dbg("Crossbill Network: Using HTTP for", url)
		result, code_or_err = http.request(request)
	end

	-- Reset socket timeout
	socketutil:reset_timeout()

	-- LuaSocket answers `nil, message` for a request that never completed, and
	-- `1, status` for one that did. Told apart by the first value: the message
	-- travels where a status would, so testing the second alone would report a
	-- timeout as though it were an HTTP status.
	if not result then
		local err = code_or_err or "Unknown network error"
		logger.dbg("Crossbill Network: Request failed:", tostring(err))
		return nil, "", tostring(err)
	end

	logger.dbg("Crossbill Network: Response code:", code_or_err)

	return code_or_err, table.concat(response_body), nil
end

--- Make a JSON POST request
-- @param url string The URL to request
-- @param data table The data to JSON-encode and send
-- @param token string|nil Bearer token for authorization
-- @return number|nil HTTP status code
-- @return table|nil Parsed JSON response
-- @return string|nil Error message
function Network.postJson(url, data, token)
	local body = JSON.encode(data)

	local headers = {
		["Content-Type"] = "application/json",
		["Accept"] = "application/json",
	}

	if token then
		headers["Authorization"] = "Bearer " .. token
	end

	local code, response_text, err = Network.request({
		url = url,
		method = "POST",
		headers = headers,
		body = body,
	})

	if not code then
		return nil, nil, err
	end

	return decodedResponse(code, response_text)
end

--- Make a JSON GET request
-- @param url string The URL to request
-- @param token string|nil Bearer token for authorization
-- @param extra_headers table|nil Headers a particular host insists on, added
--   last so a caller can also replace one of the defaults
-- @return number|nil HTTP status code
-- @return table|nil Parsed JSON response
-- @return string|nil Error message
function Network.getJson(url, token, extra_headers)
	local headers = {
		["Accept"] = "application/json",
	}

	if token then
		headers["Authorization"] = "Bearer " .. token
	end

	for name, value in pairs(extra_headers or {}) do
		headers[name] = value
	end

	local code, response_text, err = Network.request({
		url = url,
		method = "GET",
		headers = headers,
	})

	if not code then
		return nil, nil, err
	end

	return decodedResponse(code, response_text)
end

--- Make a form-urlencoded POST request
-- @param url string The URL to request
-- @param data table Key-value pairs to encode
-- @return number|nil HTTP status code
-- @return table|nil Parsed JSON response
-- @return string|nil Error message
function Network.postForm(url, data)
	-- Build form-urlencoded body
	local parts = {}
	for key, value in pairs(data) do
		table.insert(parts, Network.urlEncode(key) .. "=" .. Network.urlEncode(value))
	end
	local body = table.concat(parts, "&")

	local headers = {
		["Content-Type"] = "application/x-www-form-urlencoded",
		["Accept"] = "application/json",
	}

	local code, response_text, err = Network.request({
		url = url,
		method = "POST",
		headers = headers,
		body = body,
	})

	if not code then
		return nil, nil, err
	end

	return decodedResponse(code, response_text)
end

--- Make a multipart/form-data POST request
-- @param url string The URL to request
-- @param files table Array of file objects {name, filename, content_type, data}
-- @param token string|nil Bearer token for authorization
-- @return number|nil HTTP status code
-- @return string Response body
-- @return string|nil Error message
function Network.postMultipart(url, files, token)
	local boundary = "----CrossbillBoundary" .. os.time()
	local body_parts = {}

	for _, file in ipairs(files) do
		table.insert(body_parts, "--" .. boundary)
		table.insert(
			body_parts,
			string.format('Content-Disposition: form-data; name="%s"; filename="%s"', file.name, file.filename)
		)
		table.insert(body_parts, "Content-Type: " .. file.content_type)
		table.insert(body_parts, "")
		table.insert(body_parts, file.data)
	end
	table.insert(body_parts, "--" .. boundary .. "--")

	local body = table.concat(body_parts, "\r\n")

	local headers = {
		["Content-Type"] = "multipart/form-data; boundary=" .. boundary,
	}

	if token then
		headers["Authorization"] = "Bearer " .. token
	end

	return Network.request({
		url = url,
		method = "POST",
		headers = headers,
		body = body,
		-- A whole EPUB goes up here, and how long that legitimately takes
		-- depends on the book and the WiFi rather than on anything the plugin
		-- knows. A stalled connection still ends; a slow one is left alone.
		total_timeout = Network.NO_TOTAL_TIMEOUT,
	})
end

--- Ensure WiFi is enabled, calling callback when ready
-- @param callback function Function to call when network is available
-- @return boolean True if already online, false if waiting for connection
function Network.ensureWifiEnabled(callback)
	if NetworkMgr:willRerunWhenOnline(callback) then
		-- Network is off, NetworkMgr will call callback when online
		logger.info("Crossbill Network: WiFi is off, prompting to enable...")
		wifi_enabled_by_us = true
		return false
	else
		-- Network is already on
		logger.info("Crossbill Network: WiFi already enabled")
		wifi_enabled_by_us = false
		return true
	end
end

--- Disable WiFi if we enabled it for the sync
function Network.disableWifiIfNeeded()
	if wifi_enabled_by_us then
		logger.info("Crossbill Network: Disabling WiFi after sync")
		NetworkMgr:turnOffWifi()
		wifi_enabled_by_us = false
	else
		logger.info("Crossbill Network: WiFi was already on, leaving it enabled")
	end
end

--- Check whether the device currently has a network connection
-- Never prompts and never turns WiFi on; use it to decide whether an optional
-- network call is worth attempting. Anything other than a definite yes counts
-- as offline (KOReader returns nil rather than false on some platforms).
-- @return boolean True if the device is connected
function Network.isConnected()
	local success, connected = pcall(function()
		return NetworkMgr:isConnected()
	end)

	if not success then
		logger.dbg("Crossbill Network: Could not query connectivity:", connected)
		return false
	end

	return connected == true
end

return Network
