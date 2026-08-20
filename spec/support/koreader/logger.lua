--[[
Stub for KOReader's `logger`.

The plugin logs liberally; tests care about behaviour, not log output, so every
level is a no-op. Swap in a spy from a spec if a test ever needs to assert on a
particular log call.
]]

local logger = {}

local function noop() end

logger.dbg = noop
logger.info = noop
logger.warn = noop
logger.err = noop

return logger
