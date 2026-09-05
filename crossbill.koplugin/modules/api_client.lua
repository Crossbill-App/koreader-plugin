--[[
API Client Module for Crossbill Sync

Provides a clean interface for communicating with the Crossbill server API.
Handles highlight uploads, and other API operations.

Every public method answers the same way: `code, data, error`, where `code` is
the HTTP status the server replied with, nil when nothing answered at all, and
success is `code == 200`. The GETs and the POSTs used to disagree about that --
the POSTs handed back a boolean -- which left every caller remembering which
kind of call it was making.
]]

local AuthFailed = require("modules/auth_failed")
local Network = require("modules/network")
local UpgradeRequired = require("modules/upgrade_required")
local logger = require("logger")

-- Handle empty array JSON serialization
local JSON = require("json")
-- The most reliable way to get the marker for an empty array is to decode one
local empty_array = JSON.decode("[]") or {}

--- Fetch JSON, refusing to answer when the server turns this plugin away
-- These three wrappers are this module's only route to the network, so the
-- refusal is recognised in one place and a call added later inherits it. It is
-- raised rather than returned, which is what makes that inheritance real: a
-- returned refusal is only inherited by a caller that remembers to look for it
-- in the error slot, while a raised one travels past every step that does not
-- mention it to the one place that catches it.
-- @param url string The URL to fetch
-- @param token string|nil Bearer token for authorization
-- @return number|nil HTTP status code
-- @return table|nil Parsed JSON response
-- @return any Error message
local function getJson(url, token)
	local code, response_data, err = Network.getJson(url, token)
	local refusal = UpgradeRequired.fromResponse(code, response_data)
	if refusal then
		error(refusal, 0)
	end
	return code, response_data, err
end

--- Post JSON, refusing to answer when the server turns this plugin away
-- @param url string The URL to post to
-- @param payload table The data to send
-- @param token string|nil Bearer token for authorization
-- @return number|nil HTTP status code
-- @return table|nil Parsed JSON response
-- @return any Error message
local function postJson(url, payload, token)
	local code, response_data, err = Network.postJson(url, payload, token)
	local refusal = UpgradeRequired.fromResponse(code, response_data)
	if refusal then
		error(refusal, 0)
	end
	return code, response_data, err
end

--- Post a multipart body, refusing to answer when the server turns us away
-- @param url string The URL to post to
-- @param files table Array of file objects
-- @param token string|nil Bearer token for authorization
-- @return number|nil HTTP status code
-- @return string Response body
-- @return any Error message
local function postMultipart(url, files, token)
	local code, response_text, err = Network.postMultipart(url, files, token)
	if code ~= UpgradeRequired.STATUS then
		return code, response_text, err
	end

	-- A multipart upload hands back an undecoded body, so the detail is decoded
	-- here; one that will not decode is still a refusal, only a vaguer one.
	local decoded, body = pcall(JSON.decode, response_text)
	error(UpgradeRequired.new(decoded and body or nil), 0)
end

local ApiClient = {}
ApiClient.__index = ApiClient

--- Create a new ApiClient instance
-- @param settings Settings instance
-- @param auth Auth instance
-- @return ApiClient instance
function ApiClient:new(settings, auth)
	local instance = setmetatable({}, ApiClient)
	instance.settings = settings
	instance.auth = auth
	return instance
end

--- Send a request carrying a bearer token, once more if the token is refused
-- A token the server revoked before its recorded expiry stays cached until that
-- expiry passes, so without this every later call fails with a 401 the reader
-- can do nothing about. Forgetting the tokens sends the retry through a fresh
-- login; a second 401 is the server's answer, and is reported as one.
-- @param what string What the request carries, for the log lines
-- @param send function Called with a bearer token; returns code, body, error
-- @return number|nil HTTP status code
-- @return table|string|nil Response body
-- @return any Error message
function ApiClient:_sendAuthorized(what, send)
	--- Send once with a freshly fetched token, saying so when nothing answered
	-- @return number|nil, table|string|nil, any The status, body and error
	local function attempt()
		local token, auth_err = self.auth:getValidToken()
		if not token then
			-- No request goes out, so there is no status to report: this arrives
			-- at the wrappers below on their `not code` path, which hands the
			-- error on as it is. An auth failure that came with nothing to say is
			-- still typed, so the caller can still tell what kind it was.
			return nil, nil, auth_err or AuthFailed.new("Authentication failed")
		end

		local code, body, err = send(token)
		if not code then
			logger.err("Crossbill API: Network error for", what, err)
		end
		return code, body, err
	end

	local code, body, err = attempt()
	if code ~= 401 then
		return code, body, err
	end

	logger.info("Crossbill API: Token refused for", what, "- logging in again")
	self.auth:clearTokens()

	return attempt()
end

--- Fetch a JSON resource with the caller's bearer token
-- Every GET the plugin makes answers the same three ways: 200 with a body, 404
-- for a book the server has never been told about, and anything else a failure
-- carrying its status.
-- @param path string Path below the API root, starting with a slash
-- @param what string What is being fetched, for the log lines
-- @return number|nil HTTP status code
-- @return table|nil Response data, nil for anything but a 200 with a body
-- @return any Error message, nil on success
function ApiClient:_authorizedGet(path, what)
	local api_url = self.settings:getApiUrl() .. path

	local code, response_data, err = self:_sendAuthorized(what, function(token)
		logger.dbg("Crossbill API: Fetching", what, "from", api_url)
		return getJson(api_url, token)
	end)

	if not code then
		return nil, nil, err or "Network error"
	end

	if code == 200 and response_data then
		logger.dbg("Crossbill API: Fetched", what)
		return code, response_data, nil
	end

	if code == 404 then
		logger.dbg("Crossbill API: Book not found (404) fetching", what)
		return code, nil, nil
	end

	logger.warn("Crossbill API: Fetching", what, "failed with code:", code)
	return code, nil, "Fetch failed: " .. tostring(code)
end

--- Post a JSON payload with the caller's bearer token
-- Every POST the plugin makes answers the same two ways: 200 with a body, or a
-- failure carrying its status.
-- @param path string Path below the API root, starting with a slash
-- @param payload table The data to send
-- @param what string What is being sent, for the log lines
-- @param failure string|nil What to call a failure, "Upload failed" by default
-- @return number|nil HTTP status code
-- @return table|nil Response data, nil for anything but a 200 with a body
-- @return any Error message, nil on success
function ApiClient:_authorizedPost(path, payload, what, failure)
	local api_url = self.settings:getApiUrl() .. path

	local code, response_data, err = self:_sendAuthorized(what, function(token)
		logger.dbg("Crossbill API: Sending", what, "to", api_url)
		return postJson(api_url, payload, token)
	end)

	if not code then
		return nil, nil, err or "Network error"
	end

	if code == 200 and response_data then
		logger.info("Crossbill API: Uploaded", what)
		return code, response_data, nil
	end

	logger.warn("Crossbill API: Uploading", what, "failed with code:", code)
	return code, nil, (failure or "Upload failed") .. ": " .. tostring(code)
end

--- Post a multipart body with the caller's bearer token
-- Unlike a JSON post this asks for no body back: the status is the whole answer.
-- @param path string Path below the API root, starting with a slash
-- @param files table Array of file objects
-- @param what string What is being sent, for the log lines
-- @return number|nil HTTP status code
-- @return nil Response data, never carried by these endpoints
-- @return any Error message, nil on success
function ApiClient:_authorizedMultipart(path, files, what)
	local api_url = self.settings:getApiUrl() .. path

	local code, _, err = self:_sendAuthorized(what, function(token)
		logger.dbg("Crossbill API: Uploading", what, "to", api_url)
		return postMultipart(api_url, files, token)
	end)

	if not code then
		return nil, nil, err or "Network error"
	end

	if code == 200 then
		logger.info("Crossbill API: Uploaded", what)
		return code, nil, nil
	end

	logger.warn("Crossbill API: Uploading", what, "failed with code:", code)
	return code, nil, "Upload failed: " .. tostring(code)
end

--- Upload highlights to the server
-- Removals ride inside the upload rather than in a call of their own: one round
-- trip on an e-reader's WiFi, and one server transaction, so a sync cannot die
-- between the two halves. The field is left out entirely when there is nothing
-- to remove, which is the payload every older plugin sent.
-- @param client_book_id string The client-side book ID (hash of title|author)
-- @param highlights table Array of highlights; one the device made since its
--   last pull carries is_new, which lets the server revive a copy it had
--   removed or deleted under the same text
-- @param device_id string|nil Identifier of the device the highlights came from
-- @param removed_ids table|nil Server ids of highlights deleted on this device
-- @return number|nil HTTP status code, 200 on success
-- @return table|nil Response data containing book_id, highlights_created,
--   highlights_skipped, highlights_removed
-- @return any Error message, nil on success
function ApiClient:uploadHighlights(client_book_id, highlights, device_id, removed_ids)
	local payload = {
		client_book_id = client_book_id,
		-- An empty Lua table encodes as a JSON object, which the server rejects
		-- where it expects a list. A removal-only push carries no highlights, so
		-- the empty case has to be the decoder's array marker.
		highlights = (#highlights > 0) and highlights or empty_array,
		device_id = device_id,
		removed_ids = (removed_ids and #removed_ids > 0) and removed_ids or nil,
	}

	return self:_authorizedPost("/highlights/sync", payload, "highlights")
end

--- Get book metadata from server by client_book_id
-- @param client_book_id string The client-side book ID (hash of title|author)
-- @return number|nil HTTP status code
-- @return table|nil Response data containing book_id, bookname, author, has_ebook
-- @return any Error message, nil on success
function ApiClient:getBookMetadata(client_book_id)
	return self:_authorizedGet("/ereader/books/" .. client_book_id, "book metadata")
end

--- Get a book's chapter digests from the server by client_book_id
-- @param client_book_id string The client-side book ID (hash of title|author)
-- @return number|nil HTTP status code
-- @return table|nil Response data containing an "items" array of chapter digests
-- @return any Error message, nil on success
function ApiClient:getBookDigest(client_book_id)
	return self:_authorizedGet("/ereader/books/" .. client_book_id .. "/digest", "book digests")
end

--- Get a book's highlights from the server by client_book_id
-- The server is the master copy: this returns every live highlight of the book,
-- including ones made on other devices.
-- @param client_book_id string The client-side book ID (hash of title|author)
-- @return number|nil HTTP status code
-- @return table|nil Array of highlight items, empty when the book has none
-- @return any Error message, nil on success
function ApiClient:getHighlights(client_book_id)
	local code, response_data, err =
		self:_authorizedGet("/ereader/books/" .. client_book_id .. "/highlights", "highlights")
	if not response_data then
		return code, nil, err
	end

	-- An empty list decodes to the JSON library's array marker rather than a
	-- plain table, so copy the items into one.
	local items = {}
	if type(response_data.items) == "table" then
		for _, item in ipairs(response_data.items) do
			table.insert(items, item)
		end
	end

	logger.dbg("Crossbill API: Fetched", #items, "highlights")
	return code, items, nil
end

--- Create a new book on the server
-- @param book_data table Book metadata (title, author, isbn, description, language, page_count, client_book_id, keywords)
-- @return number|nil HTTP status code, 200 on success
-- @return table|nil Response data containing book metadata (same as getBookMetadata)
-- @return any Error message, nil on success
function ApiClient:createBook(book_data)
	return self:_authorizedPost("/ereader/books", book_data, "the new book", "Create book failed")
end

--- Upload an EPUB file for a book using client_book_id
-- @param client_book_id string The client-side book ID (hash of title|author)
-- @param epub_data string The EPUB file binary data
-- @param filename string The original EPUB filename
-- @return number|nil HTTP status code, 200 on success
-- @return nil Response data (always nil for this endpoint)
-- @return any Error message, nil on success
function ApiClient:uploadEpub(client_book_id, epub_data, filename)
	local files = {
		{
			name = "epub",
			filename = filename,
			content_type = "application/epub+zip",
			data = epub_data,
		},
	}

	return self:_authorizedMultipart("/ereader/books/" .. client_book_id .. "/epub", files, "the EPUB")
end

local function unixToISO8601(timestamp)
	if not timestamp then
		return nil
	end
	-- Convert to number (handles LuaJIT cdata int64 from SQLite)
	local ts = tonumber(timestamp)
	if not ts then
		return nil
	end
	return os.date("!%Y-%m-%dT%H:%M:%SZ", ts)
end

--- Upload reading sessions to the server for a single book
-- @param client_book_id string The client-side book ID (hash of title|author)
-- @param sessions table Array of session records from SessionTracker
-- @return number|nil HTTP status code, 200 on success
-- @return table|nil Response data (success, message, created_count, skipped_duplicate_count)
-- @return any Error message, nil on success
function ApiClient:uploadReadingSessions(client_book_id, sessions)
	-- Transform sessions to API format
	local api_sessions = {}
	for _, session in ipairs(sessions) do
		local api_session = {
			start_time = unixToISO8601(session.start_time),
			end_time = unixToISO8601(session.end_time),
			device_id = session.device_id,
			start_page = session.start_page and tonumber(session.start_page) or 0,
			end_page = session.end_page and tonumber(session.end_page) or 0,
		}

		-- Map position data based on type
		if session.position_type == "xpointer" then
			api_session.start_xpoint = session.start_position
			api_session.end_xpoint = session.end_position
		else
			api_session.start_xpoint = ""
			api_session.end_xpoint = ""
		end

		table.insert(api_sessions, api_session)
	end

	logger.info("Crossbill API: Prepared", #api_sessions, "sessions for upload")

	local payload = {
		client_book_id = client_book_id,
		sessions = (#api_sessions > 0) and api_sessions or empty_array,
	}

	return self:_authorizedPost("/reading_sessions/sync", payload, "reading sessions")
end

return ApiClient
