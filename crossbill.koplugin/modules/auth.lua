--[[
Authentication Module for Crossbill Sync

Handles user authentication with the Crossbill server including:
- Initial login with username/password
- Token refresh using refresh tokens
- Token validation and caching

A failure the reader could do something about -- credentials that are missing or
that the server rejected -- comes back as an AuthFailed, so the sync path can
tell it from every other error without reading its wording. A network error on
the way to the login endpoint stays a plain string: nothing is wrong with the
reader's credentials, and dressing it up as an authentication failure would send
them to change a password that works.
]]

local AuthFailed = require("modules/auth_failed")
local Network = require("modules/network")
local logger = require("logger")

local Auth = {}
Auth.__index = Auth

-- Buffer time before token expiry (in seconds) to trigger refresh
local TOKEN_EXPIRY_BUFFER = 60

--- Create a new Auth instance
-- @param settings Settings instance
-- @return Auth instance
function Auth:new(settings)
	local instance = setmetatable({}, Auth)
	instance.settings = settings
	return instance
end

--- Authenticate with username and password
-- @return string|nil Access token on success
-- @return any Error on failure: an AuthFailed when the credentials are the
--   problem, a plain message when the network is
function Auth:login()
	local username = self.settings:getUsername()
	local password = self.settings:getPassword()

	if username == "" or password == "" then
		logger.warn("Crossbill Auth: Username or password not configured")
		return nil, AuthFailed.new("Username or password not configured")
	end

	local api_url = self.settings:getApiUrl() .. "/auth/login"
	logger.dbg("Crossbill Auth: Logging in to", api_url)

	local code, response_data, err = Network.postForm(api_url, {
		username = username,
		password = password,
	})

	if not code then
		logger.err("Crossbill Auth: Network error during login:", err)
		return nil, err or "Network error"
	end

	if code == 200 and response_data and response_data.access_token then
		logger.dbg("Crossbill Auth: Login successful")
		self.settings:setTokens(response_data.access_token, response_data.refresh_token, response_data.expires_in)
		return response_data.access_token
	else
		logger.err("Crossbill Auth: Login failed with code:", code)
		return nil, AuthFailed.new("Login failed: " .. tostring(code))
	end
end

--- Refresh the access token using stored refresh token
-- @return string|nil New access token on success
-- @return any Error on failure: an AuthFailed when the stored tokens are the
--   problem, a plain message when the network is
function Auth:refreshToken()
	local refresh_token = self.settings:getRefreshToken()
	if not refresh_token then
		logger.dbg("Crossbill Auth: No refresh token available")
		return nil, AuthFailed.new("No refresh token")
	end

	local api_url = self.settings:getApiUrl() .. "/auth/refresh"
	logger.dbg("Crossbill Auth: Refreshing token at", api_url)

	local code, response_data, err = Network.postJson(api_url, {
		refresh_token = refresh_token,
	})

	if not code then
		logger.err("Crossbill Auth: Network error during refresh:", err)
		return nil, err or "Network error"
	end

	if code == 200 and response_data and response_data.access_token then
		logger.dbg("Crossbill Auth: Token refresh successful")
		self.settings:setTokens(response_data.access_token, response_data.refresh_token, response_data.expires_in)
		return response_data.access_token
	else
		logger.err("Crossbill Auth: Token refresh failed with code:", code)
		-- Clear stored tokens on refresh failure
		self.settings:clearTokens()
		return nil, AuthFailed.new("Refresh failed: " .. tostring(code))
	end
end

--- Forget the stored tokens, so the next call authenticates afresh
-- The server can revoke a token before the expiry the plugin recorded; a caller
-- turned away with a 401 says so here, and the next `getValidToken` logs in.
function Auth:clearTokens()
	logger.dbg("Crossbill Auth: Clearing stored tokens")
	self.settings:clearTokens()
end

--- Get a valid access token, refreshing or logging in as needed
-- A failed refresh is not reported: it falls through to a full login, and it is
-- that login's answer -- an AuthFailed, or a plain network message -- the caller
-- is handed.
-- @return string|nil Access token on success
-- @return any Error on failure, as `login` reports it
function Auth:getValidToken()
	local current_time = os.time()
	local expires_at = self.settings:getTokenExpiresAt()
	local access_token = self.settings:getAccessToken()

	-- Check if we have a cached token that's still valid (with buffer)
	if access_token and expires_at and (expires_at - TOKEN_EXPIRY_BUFFER) > current_time then
		logger.dbg("Crossbill Auth: Using cached access token")
		return access_token
	end

	-- Try to refresh the token if we have a refresh token
	local refresh_token = self.settings:getRefreshToken()
	if refresh_token then
		logger.dbg("Crossbill Auth: Access token expired or missing, trying refresh")
		local token, err = self:refreshToken()
		if token then
			return token
		end
		logger.dbg("Crossbill Auth: Refresh failed:", err)
	end

	-- Fall back to full login
	logger.dbg("Crossbill Auth: Falling back to full login")
	return self:login()
end

return Auth
