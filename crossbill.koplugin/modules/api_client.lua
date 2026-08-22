--[[
API Client Module for Crossbill Sync

Provides a clean interface for communicating with the Crossbill server API.
Handles highlight uploads, and other API operations.
]]

local Network = require("modules/network")
local UpgradeRequired = require("modules/upgrade_required")
local logger = require("logger")

-- Handle empty array JSON serialization
local JSON = require("json")
-- The most reliable way to get the marker for an empty array is to decode one
local empty_array = JSON.decode("[]") or {}

--- Fetch JSON, recognising a server that refuses this plugin version
-- These three wrappers are this module's only route to the network, so the
-- refusal is recognised in one place and a call added later inherits it.
-- @param url string The URL to fetch
-- @param token string|nil Bearer token for authorization
-- @return number|nil HTTP status code
-- @return table|nil Parsed JSON response
-- @return any Error message, or the upgrade error when the plugin was refused
local function getJson(url, token)
	local code, response_data, err = Network.getJson(url, token)
	return code, response_data, UpgradeRequired.fromResponse(code, response_data) or err
end

--- Post JSON, recognising a server that refuses this plugin version
-- @param url string The URL to post to
-- @param payload table The data to send
-- @param token string|nil Bearer token for authorization
-- @return number|nil HTTP status code
-- @return table|nil Parsed JSON response
-- @return any Error message, or the upgrade error when the plugin was refused
local function postJson(url, payload, token)
	local code, response_data, err = Network.postJson(url, payload, token)
	return code, response_data, UpgradeRequired.fromResponse(code, response_data) or err
end

--- Post a multipart body, recognising a server that refuses this plugin version
-- @param url string The URL to post to
-- @param files table Array of file objects
-- @param token string|nil Bearer token for authorization
-- @return number|nil HTTP status code
-- @return string Response body
-- @return any Error message, or the upgrade error when the plugin was refused
local function postMultipart(url, files, token)
	local code, response_text, err = Network.postMultipart(url, files, token)
	if code ~= UpgradeRequired.STATUS then
		return code, response_text, err
	end

	-- A multipart upload hands back an undecoded body, so the detail is decoded
	-- here; one that will not decode is still a refusal, only a vaguer one.
	local decoded, body = pcall(JSON.decode, response_text)
	return code, response_text, UpgradeRequired.new(decoded and body or nil)
end

--- Keep the server's refusal, or describe the failure by its status
-- A refusal has to survive as itself: it is the one failure the plugin acts on
-- rather than merely reports.
-- @param err any The error the request came back with
-- @param message string What to say about any other failure
-- @return any The error to report
local function failureError(err, message)
	if UpgradeRequired.is(err) then
		return err
	end
	return message
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

--- Get the API base URL
-- @return string API base URL
function ApiClient:getApiUrl()
	return self.settings:getBaseUrl() .. "/api/v1"
end

--- Fetch a JSON resource with the caller's bearer token
-- Every GET the plugin makes answers the same three ways: 200 with a body, 404
-- for a book the server has never been told about, and anything else a failure
-- carrying its status.
-- @param path string Path below the API root, starting with a slash
-- @param what string What is being fetched, for the log lines
-- @return number|nil HTTP status code
-- @return table|nil Response data, nil for anything but a 200 with a body
-- @return string|nil Error message
function ApiClient:_authorizedGet(path, what)
	local token, auth_err = self.auth:getValidToken()
	if not token then
		return nil, nil, auth_err or "Authentication failed"
	end

	local api_url = self:getApiUrl() .. path
	logger.dbg("Crossbill API: Fetching", what, "from", api_url)

	local code, response_data, err = getJson(api_url, token)

	if not code then
		logger.err("Crossbill API: Network error fetching", what, err)
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
	return code, nil, failureError(err, "Fetch failed: " .. tostring(code))
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
-- @return boolean Success status
-- @return table|nil Response data containing book_id, highlights_created,
--   highlights_skipped, highlights_removed
-- @return string|nil Error message
function ApiClient:uploadHighlights(client_book_id, highlights, device_id, removed_ids)
	local token, auth_err = self.auth:getValidToken()
	if not token then
		return false, nil, auth_err or "Authentication failed"
	end

	local payload = {
		client_book_id = client_book_id,
		-- An empty Lua table encodes as a JSON object, which the server rejects
		-- where it expects a list. A removal-only push carries no highlights, so
		-- the empty case has to be the decoder's array marker.
		highlights = (#highlights > 0) and highlights or empty_array,
		device_id = device_id,
		removed_ids = (removed_ids and #removed_ids > 0) and removed_ids or nil,
	}

	local api_url = self:getApiUrl() .. "/highlights/upload"
	logger.dbg("Crossbill API: Sending highlights to", api_url)

	local code, response_data, err = postJson(api_url, payload, token)

	if not code then
		logger.err("Crossbill API: Network error:", err)
		return false, nil, err or "Network error"
	end

	if code == 200 and response_data then
		logger.dbg("Crossbill API: Highlights uploaded successfully")
		return true, response_data, nil
	else
		logger.err("Crossbill API: Upload failed with code:", code)
		return false, nil, failureError(err, "Upload failed: " .. tostring(code))
	end
end

--- Get book metadata from server by client_book_id
-- @param client_book_id string The client-side book ID (hash of title|author)
-- @return number|nil HTTP status code
-- @return table|nil Response data containing book_id, bookname, author, has_ebook
-- @return string|nil Error message
function ApiClient:getBookMetadata(client_book_id)
	return self:_authorizedGet("/ereader/books/" .. client_book_id, "book metadata")
end

--- Get a book's chapter digests from the server by client_book_id
-- @param client_book_id string The client-side book ID (hash of title|author)
-- @return number|nil HTTP status code
-- @return table|nil Response data containing an "items" array of chapter digests
-- @return string|nil Error message
function ApiClient:getBookDigest(client_book_id)
	return self:_authorizedGet("/ereader/books/" .. client_book_id .. "/digest", "book digests")
end

--- Get a book's highlights from the server by client_book_id
-- The server is the master copy: this returns every live highlight of the book,
-- including ones made on other devices.
-- @param client_book_id string The client-side book ID (hash of title|author)
-- @return number|nil HTTP status code
-- @return table|nil Array of highlight items, empty when the book has none
-- @return string|nil Error message
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
-- @return boolean Success status
-- @return table|nil Response data containing book metadata (same as getBookMetadata)
-- @return string|nil Error message
function ApiClient:createBook(book_data)
	local token, auth_err = self.auth:getValidToken()
	if not token then
		return false, nil, auth_err or "Authentication failed"
	end

	local api_url = self:getApiUrl() .. "/ereader/books"
	logger.dbg("Crossbill API: Creating book on server", api_url)

	local code, response_data, err = postJson(api_url, book_data, token)

	if not code then
		logger.err("Crossbill API: Network error creating book:", err)
		return false, nil, err or "Network error"
	end

	if code == 200 and response_data then
		logger.info("Crossbill API: Book created successfully")
		return true, response_data, nil
	else
		logger.err("Crossbill API: Create book failed with code:", code)
		return false, nil, failureError(err, "Create book failed: " .. tostring(code))
	end
end

--- Upload an EPUB file for a book using client_book_id
-- @param client_book_id string The client-side book ID (hash of title|author)
-- @param epub_data string The EPUB file binary data
-- @param filename string The original EPUB filename
-- @return boolean Success status
-- @return nil Response data (always nil for this endpoint)
-- @return string|nil Error message
function ApiClient:uploadEpub(client_book_id, epub_data, filename)
	local token, auth_err = self.auth:getValidToken()
	if not token then
		return false, nil, auth_err or "Authentication failed"
	end

	local api_url = self:getApiUrl() .. "/ereader/books/" .. client_book_id .. "/epub"
	logger.dbg("Crossbill API: Uploading EPUB to", api_url)

	local files = {
		{
			name = "epub",
			filename = filename,
			content_type = "application/epub+zip",
			data = epub_data,
		},
	}

	local code, _, err = postMultipart(api_url, files, token)

	if not code then
		logger.err("Crossbill API: Network error uploading EPUB:", err)
		return false, nil, err or "Network error"
	end

	if code == 200 then
		logger.info("Crossbill API: EPUB uploaded successfully for book", client_book_id)
		return true, nil, nil
	else
		logger.warn("Crossbill API: EPUB upload failed with code:", code)
		return false, nil, failureError(err, "Upload failed: " .. tostring(code))
	end
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
-- @return boolean Success status
-- @return table|nil Response data (success, message, created_count, skipped_duplicate_count)
-- @return string|nil Error message
function ApiClient:uploadReadingSessions(client_book_id, sessions)
	local token, auth_err = self.auth:getValidToken()
	if not token then
		return false, nil, auth_err or "Authentication failed"
	end

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

	local api_url = self:getApiUrl() .. "/reading_sessions/upload"
	logger.dbg("Crossbill API: Sending", #api_sessions, "reading sessions to", api_url)

	local code, response_data, err = postJson(api_url, payload, token)

	if not code then
		logger.err("Crossbill API: Network error:", err)
		return false, nil, err or "Network error"
	end

	if code == 200 and response_data then
		logger.info("Crossbill API: Reading sessions uploaded successfully")
		return true, response_data, nil
	else
		logger.warn("Crossbill API: Reading sessions upload failed with code:", code)
		return false, nil, failureError(err, "Upload failed: " .. tostring(code))
	end
end

return ApiClient
