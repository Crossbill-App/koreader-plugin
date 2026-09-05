--[[
The bound logger is the one place that decides how a log prefix is spelled, and
about a hundred and sixty call sites now take it on trust. What is worth pinning
is that the prefix goes out as the first argument and everything else reaches
KOReader's logger untouched -- a bound logger that swallowed or reordered an
argument would show up on a device as a message missing its detail, which is
exactly when nobody is in a position to notice.
]]

local logger = require("logger")
local PluginIdentity = require("modules/plugin_identity")
local Log = require("modules/log")

local LEVELS = { "dbg", "info", "warn", "err" }

describe("Log.forModule", function()
	it("sends every level on to the logger with the prefix in front", function()
		local log = Log.forModule("SyncService")

		for _, level in ipairs(LEVELS) do
			local sent = spy.on(logger, level)

			log[level]("Found", 3, "unsynced reading sessions")

			assert.spy(sent).was_called_with("Crossbill SyncService:", "Found", 3, "unsynced reading sessions")
			logger[level]:revert()
		end
	end)

	it("passes a call with nothing to say", function()
		local log = Log.forModule("Auth")
		local sent = spy.on(logger, "dbg")

		log.dbg()

		assert.spy(sent).was_called_with("Crossbill Auth:")
		logger.dbg:revert()
	end)

	it("keeps a nil in the middle of the arguments", function()
		-- A logger that dropped one would turn "Failed: nil" into "Failed:",
		-- which reads like a success.
		local log = Log.forModule("ApiClient")
		local sent = spy.on(logger, "err")

		log.err("Request failed:", nil, "after 2 tries")

		assert.spy(sent).was_called_with("Crossbill ApiClient:", "Request failed:", nil, "after 2 tries")
		logger.err:revert()
	end)

	it("names the plugin as the identity does, so the test build is its own", function()
		-- The side-by-side test build is called "Crossbill Test", and logs as
		-- "Crossbill Test SyncService:" -- which is what lets one device log be
		-- read as two plugins rather than one confusing one.
		local log = Log.forModule("SessionTracker")

		assert.are.equal(PluginIdentity.display_name .. " SessionTracker:", log.prefix)
		assert.are.equal("Crossbill SessionTracker:", log.prefix)
	end)

	it("gives each module its own prefix", function()
		assert.are.equal("Crossbill Network:", Log.forModule("Network").prefix)
		assert.are.equal("Crossbill UpdateInstaller:", Log.forModule("UpdateInstaller").prefix)
	end)
end)
