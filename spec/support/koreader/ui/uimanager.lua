--[[
Stub for KOReader's `ui/uimanager`.

The plugin only ever asks the manager to repaint or to show and close widgets.
None of that is observable outside the reader, so every method is a no-op. A
spec that cares whether a repaint was requested should spy on the method:

	local spy_setDirty = spy.on(UIManager, "setDirty")
]]

local UIManager = {}

local function noop() end

UIManager.setDirty = noop
UIManager.forceRePaint = noop
UIManager.show = noop
UIManager.close = noop
UIManager.scheduleIn = noop
UIManager.unschedule = noop
-- KOReader's own restart prompt: it decides per platform whether restarting is
-- possible at all, so the plugin asks rather than restarting by itself.
UIManager.askForRestart = noop

-- The device installs these at startup, and `askForRestart` does nothing
-- without them. Present here, since a running reader is what the specs stand
-- for; a spec that wants the other case clears it and puts it back.
UIManager.event_handlers = { PowerOff = noop }

return UIManager
