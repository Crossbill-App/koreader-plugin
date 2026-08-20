--[[
Device Identity Module for Crossbill Sync

Provides a stable identifier for this device, shared by reading sessions and
highlight uploads. The model name alone cannot tell two devices of the same
model apart, so a UUID is appended: KOReader's own annotation-export UUID when
it exists, otherwise one generated once and kept in the plugin settings.
]]

local Device = require("device")
local Settings = require("modules/settings")
local logger = require("logger")
local random = require("random")

local DeviceIdentity = {}

-- The server accepts at most 100 characters for a device id
local MAX_LENGTH = 100
local UUID_PREFIX_LENGTH = 8
local UUID_SETTING_KEY = "device_uuid"

local cached_device_id = nil

local function isNonEmptyString(value)
	return type(value) == "string" and value ~= ""
end

local function getUuid()
	local koreader_uuid = G_reader_settings:readSetting("device_id")
	if isNonEmptyString(koreader_uuid) then
		return koreader_uuid
	end

	local stored_uuid = Settings.readShared(UUID_SETTING_KEY)
	if isNonEmptyString(stored_uuid) then
		return stored_uuid
	end

	local uuid = random.uuid()
	Settings.saveShared(UUID_SETTING_KEY, uuid)
	logger.dbg("Crossbill DeviceIdentity: Generated a device UUID")
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
