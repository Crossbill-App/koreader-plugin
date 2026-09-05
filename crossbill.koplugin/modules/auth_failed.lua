--[[
Authentication Failure Module for Crossbill Sync

The plugin picks which dialog a reader sees by what kind of failure a sync ran
into, and until this module existed it did that by matching the error's text:
`main.lua` looked for a message starting with "Authentication". Auth never
produced one -- its messages are "Login failed: 401", "No refresh token" and
their siblings -- so the authentication dialog was unreachable and a reader with
a wrong password was told "Sync failed: Login failed: 401". Nothing failed
loudly enough to notice, which is what matching on prose gets you.

A failure that a caller acts on therefore travels as a type, the way
`modules/upgrade_required.lua` does. Like that one, this error rides in the
plugin's usual error slot, which everything else fills with a string, so it
carries `__tostring` and `__concat`: a path that logs or appends whatever it was
handed prints the message instead of blowing up.

Only the failures that are the credentials' or the server's fault are wrapped. A
network error on the way to the login endpoint stays a plain string: the
reader's password is not the problem, and saying so would send them to change it.
]]

local _ = require("gettext")

local AuthFailed = {}

-- What this failure is called wherever it travels as an error kind
AuthFailed.KIND = "auth_failed"

local mt = {}

--- Tell this failure apart from the error strings everything else reports
-- @param err any The error to test
-- @return boolean True when the reader could not be authenticated
function AuthFailed.is(err)
	return type(err) == "table" and err.kind == AuthFailed.KIND
end

--- What went wrong, as the reader should hear it
-- Anything else that reached the dialog is named as it stands, because a
-- message a reader can act on is worth more than insisting on the type here.
-- Reading `message` off the table rather than calling `tostring` on it is what
-- keeps a failure that carries none out of `__tostring`'s own recursion.
-- @param err any The error, or nil when there is nothing to go on
-- @return string The message
function AuthFailed.message(err)
	if AuthFailed.is(err) then
		return type(err.message) == "string" and err.message or _("unknown error")
	end

	if err == nil then
		return _("unknown error")
	end

	return tostring(err)
end

mt.__tostring = function(err)
	return AuthFailed.message(err)
end

mt.__concat = function(left, right)
	return tostring(left) .. tostring(right)
end

--- Build the error from what the authentication attempt ran into
-- @param message string|nil What went wrong
-- @return table The error, carrying that message
function AuthFailed.new(message)
	return setmetatable({
		kind = AuthFailed.KIND,
		message = message,
	}, mt)
end

return AuthFailed
