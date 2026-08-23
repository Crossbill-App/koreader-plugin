--[[
Upgrade Required Module for Crossbill Sync

The server answers 426 when it will no longer serve this plugin version, naming
the versions involved and where to get a newer plugin. This module is the one
place that knows what that answer looks like, so a reader is told the same thing
wherever the refusal surfaces.

The error travels in the plugin's usual error slot, which everything else fills
with a string, so it carries `__tostring` and `__concat`: a path that logs or
appends whatever it was handed prints the message instead of blowing up.
]]

local meta = require("_meta")
local _ = require("gettext")

local UpgradeRequired = {}

-- The status the server turns a too-old plugin away with
UpgradeRequired.STATUS = 426

-- What this failure is called wherever it travels as an error kind
UpgradeRequired.KIND = "client_upgrade_required"

-- Where a reader gets a newer plugin, for an answer that named no address.
-- Read from `_meta.lua` rather than repeated here, so it cannot drift from the
-- address About shows.
local FALLBACK_UPDATE_URL = meta.homepage

local mt = {}

--- What the server actually named, as opposed to what merely arrived
-- Decoded JSON null is a truthy sentinel, not nil, and the server sends
-- `"received_version": null` when it cannot parse the version claimed; only a
-- real string may reach the message.
-- @param value any The field as it came off the decoded body
-- @return string|nil The value when it is a string, nil otherwise
local function named(value)
	if type(value) ~= "string" then
		return nil
	end

	return value
end

--- The message a reader is shown when the server turns the plugin away
-- Composed from the versions the server reported rather than shown as the
-- server phrased it: the plugin's own text is what can be translated.
-- @param err table|nil The error, or nil when there is nothing to go on
-- @return string The message, ending in the address to update from
function UpgradeRequired.message(err)
	local update_url = named(err and err.update_url) or FALLBACK_UPDATE_URL
	local received = named(err and err.received_version)
	local minimum = named(err and err.min_supported_version)

	if received and minimum then
		return string.format(
			_("Your Crossbill plugin (%s) is too old for this server. Please update to %s or newer."),
			received,
			minimum
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
-- A missing or unreadable body still produces the error: being turned away is
-- the fact worth reporting, and the versions only sharpen the wording.
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
