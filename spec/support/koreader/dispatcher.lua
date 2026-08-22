--[[
Stub for KOReader's `dispatcher`.

The plugin registers two gesture-bindable actions with it and never asks it
anything back. The stub keeps what it was told so a spec can check the
registration, and does nothing else: dispatching a gesture is the reader's job.
]]

local Dispatcher = {}

-- What has been registered so far, keyed by action name
Dispatcher.registered = {}

--- Register a gesture-bindable action
-- @param name string The key KOReader stores in a user's gesture settings
-- @param definition table The action's category, event, title and reader flag
function Dispatcher:registerAction(name, definition)
	Dispatcher.registered[name] = definition
end

--- Forget every registration, so one spec's actions are not another's
function Dispatcher.reset()
	Dispatcher.registered = {}
end

return Dispatcher
