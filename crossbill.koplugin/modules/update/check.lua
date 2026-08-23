--[[
Update Check Module for Crossbill Sync

Asks the release service named in `_meta.lua` what the newest published version
is and compares it with the one running. Nothing here installs anything: the
answer is a report for the reader to act on.

The comparison is deliberately strict. The Release workflow only ever publishes
`vMAJOR.MINOR.PATCH`, so a tag in any other shape means something upstream went
wrong, and a guess would report a comparison that was never made.
]]

local Network = require("modules/network")
local meta = require("_meta")

local UpdateCheck = {}

-- What the Release workflow attaches to a release: the archive, and the
-- detached signature the installer refuses to proceed without. Facts about that
-- workflow rather than about the plugin's identity, so they stay here rather
-- than joining the fields in `_meta.lua`.
local ARCHIVE_NAME = "crossbill.koplugin.zip"
local SIGNATURE_NAME = ARCHIVE_NAME .. ".sig"

-- Names the plugin to the release service. GitHub refuses a request carrying no
-- User-Agent at all, and answering as the socket library would leave the plugin
-- unnameable in anyone's logs.
local USER_AGENT = "koreader-plugin/" .. tostring(meta.version)

--- The three numbers of a version, or nothing when it is not one
-- @param version any The version, with or without a leading `v`
-- @return number|nil, number|nil, number|nil The major, minor and patch
local function parse(version)
	if type(version) ~= "string" then
		return nil
	end

	local major, minor, patch = version:match("^v?(%d+)%.(%d+)%.(%d+)$")
	if not major then
		return nil
	end

	return tonumber(major), tonumber(minor), tonumber(patch)
end

--- A version without the tag's leading `v`, for showing to a reader
-- @param version string The version as the service named it
-- @return string The version as the plugin writes its own
local function withoutPrefix(version)
	return (version:gsub("^v", ""))
end

--- Order two versions by number rather than by text
-- Numeric on purpose: compared as text, "10.0.0" sorts below "9.0.0".
-- @param left string The version on the left
-- @param right string The version on the right
-- @return number|nil -1, 0 or 1, and nil when either is not a version
function UpdateCheck.compareVersions(left, right)
	local left_parts = { parse(left) }
	local right_parts = { parse(right) }

	if #left_parts == 0 or #right_parts == 0 then
		return nil
	end

	for index = 1, 3 do
		if left_parts[index] ~= right_parts[index] then
			return left_parts[index] < right_parts[index] and -1 or 1
		end
	end

	return 0
end

--- Where one of the release's attachments can be downloaded, if it has it
-- A release missing an attachment is still a release: the version is the fact
-- worth reporting, and a reader can always install by hand. Reporting the
-- version is what tells them there is anything to install.
-- @param release table The decoded release
-- @param name string The attachment's filename
-- @return string|nil The address, nil when no attachment matches
local function assetUrl(release, name)
	if type(release.assets) ~= "table" then
		return nil
	end

	for _index, asset in ipairs(release.assets) do
		if type(asset) == "table" and asset.name == name then
			return type(asset.browser_download_url) == "string" and asset.browser_download_url or nil
		end
	end

	return nil
end

--- Ask the release service what the newest published version is
-- The error is written for the log rather than for the reader: nothing a
-- reader could do differs between a 404 and a timeout, so the message they see
-- is chosen by the UI, not here.
-- @return boolean True when the check completed
-- @return table|nil What was learned: current, latest, update_available,
--   ahead, release_url, and download_url and signature_url (either may be nil,
--   and the update can only be installed when both are there)
-- @return string|nil What went wrong
function UpdateCheck.check()
	local url = meta.update_check_url
	if type(url) ~= "string" or url == "" then
		return false, nil, "no update_check_url in _meta.lua"
	end

	local code, body, err = Network.getJson(url, nil, { ["User-Agent"] = USER_AGENT })

	if not code then
		return false, nil, tostring(err or "no response")
	end

	if code ~= 200 then
		return false, nil, "HTTP " .. tostring(code)
	end

	if type(body) ~= "table" then
		return false, nil, "the answer was not a release"
	end

	local current = meta.version
	local latest = body.tag_name
	local order = UpdateCheck.compareVersions(current, latest)
	if not order then
		return false,
			nil,
			string.format("could not read the versions (running %s, latest %s)", tostring(current), tostring(latest))
	end

	return true,
		{
			current = withoutPrefix(current),
			latest = withoutPrefix(latest),
			update_available = order < 0,
			ahead = order > 0,
			release_url = type(body.html_url) == "string" and body.html_url or meta.homepage,
			download_url = assetUrl(body, ARCHIVE_NAME),
			signature_url = assetUrl(body, SIGNATURE_NAME),
		},
		nil
end

return UpdateCheck
