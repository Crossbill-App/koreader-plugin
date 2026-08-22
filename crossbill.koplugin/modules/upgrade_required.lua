--[[
Upgrade Required Module for Crossbill Sync

The server refuses plugin versions it no longer supports, answering 426 with
the versions involved and where to get a newer plugin. This module is the one
place that knows what that answer looks like: the api client turns a 426 into
the error built here, and every screen that has to report it asks here for the
words, so a reader is told the same thing wherever the refusal surfaces.

The error travels in the plugin's usual error slot, which everything else fills
with a string, so it carries a `__tostring` and a `__concat`: an older path that
logs or appends whatever it was handed still prints the message instead of
blowing up on a table.
]]

local _ = require("gettext")

local UpgradeRequired = {}

-- The status the server turns a too-old plugin away with
UpgradeRequired.STATUS = 426

-- What this failure is called wherever it travels as an error kind
UpgradeRequired.KIND = "client_upgrade_required"

-- Where a reader gets a newer plugin. The server names it too; this stands in
-- for an answer that arrived without one.
local FALLBACK_UPDATE_URL = "https://github.com/Crossbill-App/koreader-plugin"

local mt = {}

--- The message a reader is shown when the server turns the plugin away
-- Composed here from the versions the server reported rather than shown as the
-- server phrased it: the text belongs to the plugin, which is what can
-- translate it and what knows it is talking to a reader rather than to a log.
-- @param err table|nil The error, or nil when there is nothing to go on
-- @return string The message, ending in the address to update from
function UpgradeRequired.message(err)
	local update_url = (err and err.update_url) or FALLBACK_UPDATE_URL
	local received = err and err.received_version
	local minimum = err and err.min_supported_version

	if received and minimum then
		return string.format(
			_("Your Crossbill plugin (%s) is too old for this server. Please update to %s or newer."),
			tostring(received),
			tostring(minimum)
		) .. "\n" .. update_url
	end

	return _("Your Crossbill plugin is too old for this server. Please update it.") .. "\n" .. update_url
end

mt.__tostring = function(err)
	return UpgradeRequired.message(err)
end

mt.__concat = function(left, right)
	return tostring(left) .. tostring(right)
end

--- Build the error from what a 426 answer carried
-- A body that never arrived, or one nothing could be made of, still produces
-- the error: being turned away is the fact worth reporting, and the versions
-- only sharpen the wording.
-- @param body table|nil The decoded response body
-- @return table The error, carrying whatever the body named
function UpgradeRequired.new(body)
	local detail = (type(body) == "table" and type(body.detail) == "table") and body.detail or {}

	return setmetatable({
		kind = UpgradeRequired.KIND,
		min_supported_version = detail.min_supported_version,
		received_version = detail.received_version,
		update_url = detail.update_url,
	}, mt)
end

--- Recognise the answer that turns this plugin away
-- @param code number|nil The HTTP status the server answered with
-- @param body table|nil The decoded response body, if there was one
-- @return table|nil The error, nil for any other status
function UpgradeRequired.fromResponse(code, body)
	if code ~= UpgradeRequired.STATUS then
		return nil
	end

	return UpgradeRequired.new(body)
end

--- Tell this failure apart from the error strings everything else reports
-- @param err any The error to test
-- @return boolean True when the server refused this plugin version
function UpgradeRequired.is(err)
	return type(err) == "table" and err.kind == UpgradeRequired.KIND
end

return UpgradeRequired
