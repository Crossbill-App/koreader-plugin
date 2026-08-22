--[[
Stub for KOReader's `ui/widget/container/widgetcontainer`.

The plugin uses it for exactly one thing: `WidgetContainer:extend({...})` at the
top of main.lua, which hands back the table the plugin hangs its methods on.
Everything a real widget container does -- layout, painting, event dispatch --
happens inside the reader and is not observable from here, so none of it is
stubbed. A spec builds its own instance rather than asking the class for one.
]]

local WidgetContainer = {}

--- Derive a widget class from this one
-- @param subclass table|nil The fields the new class starts out with
-- @return table The new class, falling back to this one for what it lacks
function WidgetContainer:extend(subclass)
	subclass = subclass or {}
	subclass.__index = subclass
	return setmetatable(subclass, { __index = self })
end

return WidgetContainer
