--[[
Stub for KOReader's `ui/event`.

The real Event is a plain record of a handler name and the arguments to call it
with; the reader's widget tree does the dispatching. That record is all the
plugin builds, so the stub reproduces it, adding `name` so a spec can assert on
the event without stripping the "on" prefix itself.

`args` is a list rather than `table.pack`'s result: the plugin never reads it,
and `table.pack` is a 5.2 addition that LuaJIT only exposes with its 5.2
compatibility layer on.
]]

local Event = {}
Event.__index = Event

--- Build an event named `name`, to be handled by `on<name>`
-- @param name string The event name
-- @param ... mixed The event's arguments
-- @return table The event record
function Event:new(name, ...)
	return setmetatable({ name = name, handler = "on" .. name, args = { ... } }, Event)
end

return Event
