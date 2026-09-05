--[[
Device Identity Module for Crossbill Sync

Provides a stable identifier for this device, shared by reading sessions and
highlight uploads. The model name alone cannot tell two devices of the same
model apart, so a UUID is appended: KOReader's own annotation-export UUID when
it exists, otherwise one generated once and kept in the plugin settings.
]]

local Device = require("device")
local Settings = require("modules/settings")
local Log = require("modules/log")
local log = Log.forModule("DeviceIdentity")
local random = require("random")

local DeviceIdentity = {}

-- The server accepts at most 100 characters for a device id
local MAX_LENGTH = 100
local UUID_PREFIX_LENGTH = 8

local cached_device_id = nil

local function isNonEmptyString(value)
	return type(value) == "string" and value ~= ""
end

local function getUuid()
	local koreader_uuid = G_reader_settings:readSetting("device_id")
	if isNonEmptyString(koreader_uuid) then
		return koreader_uuid
	end

	-- Its own Settings instance rather than an injected one: getDeviceId takes no
	-- arguments -- SessionTracker and SyncService call it without a settings
	-- object -- and every instance shares the one table G_reader_settings holds,
	-- so this sees and is seen by the plugin's own instance.
	local settings = Settings:new():load()
	local stored_uuid = settings:getDeviceUuid()
	if isNonEmptyString(stored_uuid) then
		return stored_uuid
	end

	local uuid = random.uuid()
	settings:setDeviceUuid(uuid)
	log.dbg("Generated a device UUID")
	return uuid
end

--- Get a stable identifier for this device
-- Format is "<model>-<8 hex characters>", never longer than 100 characters.
-- The value is computed once per KOReader run.
-- @return string Device ID
function DeviceIdentity.getDeviceId()
	if cached_device_id then
		return cached_device_id
	end

	local model = isNonEmptyString(Device.model) and Device.model or "unknown"
	local suffix = getUuid():gsub("%-", ""):sub(1, UUID_PREFIX_LENGTH):lower()
	local max_model_length = MAX_LENGTH - #suffix - 1

	if #model > max_model_length then
		model = model:sub(1, max_model_length)
	end

	cached_device_id = model .. "-" .. suffix
	return cached_device_id
end

return DeviceIdentity
