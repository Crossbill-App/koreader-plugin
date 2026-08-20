--[[
In-memory stand-in for KOReader's `G_reader_settings` global.

`Settings` reads and writes through the global, so a spec installs the fake for
the duration of a test and restores whatever was there before:

	local fake = GlobalSettingsFake.install()
	finally(fake.uninstall)

The returned handle exposes `store`, so a test can seed persisted values or
assert on what was written.
]]

local GlobalSettingsFake = {}

local Store = {}
Store.__index = Store

--- Read a top-level settings key
-- @param key string The settings key
-- @return mixed The stored value, or nil when unset
function Store:readSetting(key)
	return self.store[key]
end

--- Write a top-level settings key
-- @param key string The settings key
-- @param value mixed The value to persist
function Store:saveSetting(key, value)
	self.store[key] = value
end

--- Replace the `G_reader_settings` global with a fresh in-memory store
-- @param initial table|nil Values the store should start out holding
-- @return table A handle with `store` and `uninstall`
function GlobalSettingsFake.install(initial)
	local previous = _G.G_reader_settings
	local fake = setmetatable({ store = initial or {} }, Store)

	--- Restore the global that was in place before `install`
	function fake.uninstall()
		_G.G_reader_settings = previous
	end

	_G.G_reader_settings = fake
	return fake
end

return GlobalSettingsFake
