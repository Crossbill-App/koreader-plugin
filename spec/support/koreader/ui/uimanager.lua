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
UIManager.show = noop
UIManager.close = noop
UIManager.scheduleIn = noop
UIManager.unschedule = noop

return UIManager
