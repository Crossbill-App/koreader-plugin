--[[
Logging for Crossbill Sync

A logger bound to one module's prefix, so that no module writes a prefix out by
hand. Sixteen of them had been written that way across about a hundred and sixty
call sites -- "Crossbill API:" for the api client, "Crossbill Extractor:" for the
highlight extractor, a bare "Crossbill:" in four files -- so grepping a device
log for one module meant first guessing its nickname. Here the prefix is the
module's own name, and there is one place that decides how a prefix is spelled.

The display name comes from `modules/plugin_identity`, which means the
side-by-side test build logs as "Crossbill Test SyncService:" and the two builds
can be told apart in a single device log.

Levels are looked up on `logger` at call time rather than captured, so a spec
that spies on `logger.warn` still sees what a bound logger sends.
]]

local logger = require("logger")
local PluginIdentity = require("modules/plugin_identity")

local Log = {}

-- KOReader's four levels, in order of increasing volume of regret.
local LEVELS = { "dbg", "info", "warn", "err" }

--- Build a logger that prefixes every line with a module's name
-- Named `forModule` rather than `for`, which Lua will not have as a field name.
-- @param name string The module's name in CamelCase, e.g. "SyncService"
-- @return table A logger with dbg, info, warn and err
function Log.forModule(name)
	local prefix = PluginIdentity.display_name .. " " .. name .. ":"
	local bound = { prefix = prefix }

	for _, level in ipairs(LEVELS) do
		bound[level] = function(...)
			logger[level](prefix, ...)
		end
	end

	return bound
end

return Log
