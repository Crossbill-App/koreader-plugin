local UIManager = require("ui/uimanager")
local UpgradeRequired = require("modules/upgrade_required")

-- Requiring main.lua pulls in every module the plugin has, and one of them --
-- `modules/network` -- reaches for a socket the moment it loads. That is the
-- plugin's own module rather than one of KOReader's, so it cannot be shadowed
-- from spec/support: seeding the package cache before requiring main keeps the
-- wire out of the run, the same trick spec/api_client_spec.lua uses. What it
-- leaves behind is a plugin whose WiFi handling is these three answers, which is
-- what the sync paths below want anyway: already online, nothing to clean up.
local NetworkFake = {
	ensureWifiEnabled = function()
		return true
	end,
	disableWifiIfNeeded = function() end,
	isConnected = function()
		return true
	end,
}

local real_network = package.loaded["modules/network"]
package.loaded["modules/network"] = NetworkFake
local CrossbillSync = require("main")
package.loaded["modules/network"] = real_network

local REFUSAL = UpgradeRequired.fromResponse(426, {
	detail = {
		code = "client_upgrade_required",
		client = "koreader-plugin",
		min_supported_version = "0.13.0",
		received_version = "0.12.0",
		update_url = "https://github.com/Crossbill-App/koreader-plugin",
	},
})

describe("CrossbillSync", function()
	before_each(function()
		stub(UIManager, "show")
		stub(UIManager, "close")
	end)

	after_each(function()
		UIManager.show:revert()
		UIManager.close:revert()
	end)

	--- Build the plugin without letting init() near the databases
	-- `init` opens three SQLite files and registers a menu, none of which the
	-- paths below touch. Each spec hands over only the collaborators its path
	-- reaches for, which doubles as a statement of what that path depends on.
	-- @param fields table|nil The instance's fields
	-- @return table The plugin instance
	local function pluginWith(fields)
		return setmetatable(fields or {}, { __index = CrossbillSync })
	end

	--- Build a sync service whose every sync is refused by the server
	-- Refused the way the real one refuses: the refusal goes to the caller's
	-- callback first, and only then comes back in the result.
	-- @return table The sync service stand-in
	local function syncServiceRefusing()
		return {
			syncBook = function(_, _, opts)
				opts.on_upgrade_required(REFUSAL)
				return {
					success = false,
					upgrade_required = REFUSAL,
					error = UpgradeRequired.message(REFUSAL),
				}
			end,
		}
	end

	--- Build a sync service whose sync fails the ordinary way
	-- @param err string What went wrong
	-- @return table The sync service stand-in
	local function syncServiceFailing(err)
		return {
			syncBook = function()
				return { success = false, error = err }
			end,
		}
	end

	--- The text of every widget handed to one of the manager's stubs, in order
	-- @param stub table The `show` or `close` stub
	-- @return table Array of message texts
	local function textsPassedTo(stub_)
		local texts = {}
		for _idx, call in ipairs(stub_.calls) do
			table.insert(texts, call.vals[2].text)
		end
		return texts
	end

	--- The text of every message put on screen, in order
	-- @return table Array of message texts
	local function shownTexts()
		return textsPassedTo(UIManager.show)
	end

	--- The text of every message taken back down, in order
	-- @return table Array of message texts
	local function closedTexts()
		return textsPassedTo(UIManager.close)
	end

	describe("doSync", function()
		it("says nothing more once the server has refused the plugin", function()
			-- The refusal is the one message the attempt gets. "Sync failed: Your
			-- Crossbill plugin (0.12.0) is too old for this server..." stacked on
			-- top of it would read as a second, separate thing going wrong.
			local plugin = pluginWith({ ui = {}, sync_service = syncServiceRefusing() })

			plugin:doSync(false)

			assert.are.same({ UpgradeRequired.message(REFUSAL) }, shownTexts())
		end)

		it("tells the reader even when the sync that was refused was a silent one", function()
			-- An autosync says nothing about what it did, but a reader whose
			-- syncing has quietly stopped working is exactly who needs telling.
			local plugin = pluginWith({ ui = {}, sync_service = syncServiceRefusing() })

			plugin:doSync(true)

			assert.are.same({ UpgradeRequired.message(REFUSAL) }, shownTexts())
		end)

		it("still reports an ordinary failure the way it always did", function()
			-- Only the refusal ends the reporting early.
			local plugin = pluginWith({ ui = {}, sync_service = syncServiceFailing("Upload failed: 500") })

			plugin:doSync(false)

			assert.are.same({ "Sync failed: Upload failed: 500" }, shownTexts())
		end)
	end)

	describe("a manual sync the server refuses", function()
		it("takes the syncing message down before putting the refusal up", function()
			-- "Syncing with Crossbill..." clears itself on a timeout rather than
			-- when the sync ends, so the refusal would otherwise land on top of a
			-- message saying the sync is still going.
			local plugin = pluginWith({
				ui = { document = {} },
				sync_service = syncServiceRefusing(),
			})

			plugin:_runSync(false)

			assert.are.same({ "Syncing with Crossbill..." }, closedTexts())
			assert.are.same({
				"Syncing with Crossbill...",
				UpgradeRequired.message(REFUSAL),
			}, shownTexts())
		end)

		it("leaves nothing behind for a later sync to close", function()
			-- The widget is gone by the time the next attempt runs, and closing it
			-- twice would take down whatever has taken its place.
			local plugin = pluginWith({
				ui = { document = {} },
				sync_service = syncServiceRefusing(),
			})

			plugin:_runSync(false)

			assert.is_nil(plugin.syncing_message)
		end)
	end)

	describe("an autosync the server refuses", function()
		it("has no syncing message to take down", function()
			-- An autosync never puts one up, and the same refusal path runs.
			local plugin = pluginWith({
				ui = { document = {} },
				sync_service = syncServiceRefusing(),
			})

			plugin:_runSync(true)

			assert.are.same({}, closedTexts())
			assert.are.same({ UpgradeRequired.message(REFUSAL) }, shownTexts())
		end)
	end)

	describe("_showDigestResult", function()
		it("shows the refusal rather than a word about digests", function()
			-- The digest is beside the point: the server serves this plugin
			-- nothing until it is updated.
			pluginWith({}):_showDigestResult(nil, UpgradeRequired.KIND, REFUSAL)

			assert.are.same({ UpgradeRequired.message(REFUSAL) }, shownTexts())
		end)

		it("still reports a book the server has no digest for as it did", function()
			pluginWith({}):_showDigestResult(nil, "no_digest_for_book", nil)

			assert.are.same({
				"No digest generated for this book yet. Generate it in the Crossbill web app.",
			}, shownTexts())
		end)
	end)
end)
