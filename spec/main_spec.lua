local UIManager = require("ui/uimanager")
local UpgradeRequired = require("modules/upgrade_required")

-- Requiring main.lua loads `modules/network`, which reaches for a socket. It is
-- the plugin's own module rather than one of KOReader's, so it cannot be
-- shadowed from spec/support: seeding the package cache before requiring main
-- keeps the wire out of the run (see spec/api_client_spec.lua). The fake leaves
-- the sync paths below already online, with nothing to clean up.
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
-- Loaded while the fake was seeded, so this is the same module main holds, and
-- stubbing its check here is what the plugin will call.
local UpdateCheck = require("modules/update_check")
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
	-- paths below touch; each spec hands over only what its path reaches for.
	-- @param fields table|nil The instance's fields
	-- @return table The plugin instance
	local function pluginWith(fields)
		return setmetatable(fields or {}, { __index = CrossbillSync })
	end

	--- Build a sync service whose every sync is refused by the server
	-- Refused the way the real one does: the callback first, then the result.
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
			-- A "Sync failed: ..." message on top of the refusal would read as a
			-- second, separate thing going wrong.
			local plugin = pluginWith({ ui = {}, sync_service = syncServiceRefusing() })

			plugin:doSync(false)

			assert.are.same({ UpgradeRequired.message(REFUSAL) }, shownTexts())
		end)

		it("tells the reader even when the sync that was refused was a silent one", function()
			-- An autosync says nothing about what it did, but a reader whose
			-- syncing has stopped working needs telling.
			local plugin = pluginWith({ ui = {}, sync_service = syncServiceRefusing() })

			plugin:doSync(true)

			assert.are.same({ UpgradeRequired.message(REFUSAL) }, shownTexts())
		end)

		it("still reports an ordinary failure as a failed sync", function()
			-- Only the refusal ends the reporting early.
			local plugin = pluginWith({ ui = {}, sync_service = syncServiceFailing("Upload failed: 500") })

			plugin:doSync(false)

			assert.are.same({ "Sync failed: Upload failed: 500" }, shownTexts())
		end)
	end)

	describe("a manual sync the server refuses", function()
		it("takes the syncing message down before putting the refusal up", function()
			-- "Syncing with Crossbill..." clears on a timeout rather than when the
			-- sync ends, so the refusal would otherwise land on top of it.
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
			-- Closing it twice would take down whatever has taken its place.
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
			-- The digest is beside the point: nothing is served to this plugin
			-- until it is updated.
			pluginWith({}):_showDigestResult(nil, UpgradeRequired.KIND, REFUSAL)

			assert.are.same({ UpgradeRequired.message(REFUSAL) }, shownTexts())
		end)

		it("still reports a book the server has no digest for", function()
			pluginWith({}):_showDigestResult(nil, "no_digest_for_book", nil)

			assert.are.same({
				"No digest generated for this book yet. Generate it in the Crossbill web app.",
			}, shownTexts())
		end)
	end)
	describe("checkForUpdates", function()
		local waiting_callback

		before_each(function()
			waiting_callback = nil
			stub(NetworkFake, "disableWifiIfNeeded")
		end)

		--- Put a field back if this test replaced it
		-- A stub is a callable table where the original is a plain function,
		-- which is how the two are told apart.
		-- @param holder table The table the field lives on
		-- @param name string The field
		local function revertIfStubbed(holder, name)
			if type(holder[name]) == "table" then
				holder[name]:revert()
			end
		end

		after_each(function()
			NetworkFake.disableWifiIfNeeded:revert()
			revertIfStubbed(UpdateCheck, "check")
			revertIfStubbed(NetworkFake, "ensureWifiEnabled")
		end)

		--- Answer every check with the same outcome
		-- @param completed boolean Whether the check got an answer
		-- @param result table|nil What it learned
		-- @param err string|nil What went wrong
		local function checkReturning(completed, result, err)
			stub(UpdateCheck, "check").returns(completed, result, err)
		end

		--- Leave the device offline, keeping the callback WiFi would run
		local function wifiOff()
			stub(NetworkFake, "ensureWifiEnabled").invokes(function(callback)
				waiting_callback = callback
				return false
			end)
		end

		it("reports a newer release and puts WiFi back as it found it", function()
			checkReturning(true, {
				current = "0.12.0",
				latest = "0.13.0",
				update_available = true,
				ahead = false,
				release_url = "https://example.test/releases/tag/v0.13.0",
			})

			pluginWith({}):checkForUpdates()

			assert.are.same({ "Checking for updates..." }, closedTexts())
			assert.are.same({
				"Checking for updates...",
				"Crossbill Sync 0.13.0 is available.\nYou have 0.12.0.\n\nDownload:\nhttps://example.test/releases/tag/v0.13.0",
			}, shownTexts())
			assert.stub(NetworkFake.disableWifiIfNeeded).was_called()
		end)

		it("says the plugin is ahead rather than up to date", function()
			checkReturning(true, {
				current = "0.14.0",
				latest = "0.13.0",
				update_available = false,
				ahead = true,
			})

			pluginWith({}):checkForUpdates()

			assert.are.same({
				"Checking for updates...",
				"You are running 0.14.0.\nThe latest release is 0.13.0.",
			}, shownTexts())
		end)

		it("clears the message and the WiFi when the check fails", function()
			-- The failure path is the one that would otherwise leave a message
			-- with no timeout on screen and the radio on.
			checkReturning(false, nil, "HTTP 500")

			pluginWith({}):checkForUpdates()

			assert.are.same({ "Checking for updates..." }, closedTexts())
			assert.are.same({
				"Checking for updates...",
				"Could not check for updates. Please try again later.",
			}, shownTexts())
			assert.stub(NetworkFake.disableWifiIfNeeded).was_called()
		end)

		it("waits for WiFi rather than checking while offline", function()
			wifiOff()
			checkReturning(true, { current = "0.12.0", latest = "0.12.0", update_available = false, ahead = false })

			pluginWith({}):checkForUpdates()

			assert.are.same({}, shownTexts())
			assert.stub(UpdateCheck.check).was_not_called()

			waiting_callback()

			assert.are.same({
				"Checking for updates...",
				"Crossbill Sync 0.12.0 is the latest version.",
			}, shownTexts())
			assert.stub(NetworkFake.disableWifiIfNeeded).was_called()
		end)
	end)
end)
