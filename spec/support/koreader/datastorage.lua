--[[
Stub for KOReader's `datastorage`.

The plugin asks it for one thing: the directory the settings and the plugin's
own databases live in, which it then hands to the SQLite-backed modules. Nothing
under busted opens those databases -- see the `lua-ljsqlite3/init` stub -- so the
path is a marker rather than somewhere to write.
]]

local DataStorage = {}

--- Where KOReader keeps its settings
-- @return string A path no spec may write to
function DataStorage:getSettingsDir()
	return "/nonexistent/crossbill-spec-settings"
end

return DataStorage
