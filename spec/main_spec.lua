local UIManager = require("ui/uimanager")
local UpgradeRequired = require("modules/upgrade_required")

-- Requiring main.lua loads `modules/network`, which reaches for a socket. It is
-- the plugin's own module rather than one of KOReader's, so it cannot be
-- shadowed from spec/support: seeding the package cache before requiring main
-- keeps the wire out of the run (see spec/api_client_spec.lua). The fake leaves
-- the sync paths below already online, with nothing to clean up.
local NetworkFake = {
	whenOnline = function(fn)
		fn()
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
local UpdateCheck = require("modules/update/check")
local UpdateInstaller = require("modules/update/installer")
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
			revertIfStubbed(NetworkFake, "whenOnline")
		end)

		--- Answer every check with the same outcome
		-- @param completed boolean Whether the check got an answer
		-- @param result table|nil What it learned
		-- @param err string|nil What went wrong
		local function checkReturning(completed, result, err)
			stub(UpdateCheck, "check").returns(completed, result, err)
		end

		--- Leave the device offline, keeping the work WiFi would run
		local function wifiOff()
			stub(NetworkFake, "whenOnline").invokes(function(fn)
				waiting_callback = fn
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
	describe("installUpdate", function()
		local UIManagerModule = require("ui/uimanager")
		local AVAILABLE = {
			current = "0.13.0",
			latest = "0.14.0",
			update_available = true,
			ahead = false,
			release_url = "https://example.test/releases/tag/v0.14.0",
			download_url = "https://example.test/crossbill.koplugin.zip",
			signature_url = "https://example.test/crossbill.koplugin.zip.sig",
		}

		before_each(function()
			stub(NetworkFake, "disableWifiIfNeeded")
			stub(UIManagerModule, "askForRestart")
		end)

		after_each(function()
			NetworkFake.disableWifiIfNeeded:revert()
			UIManagerModule.askForRestart:revert()
			if type(UpdateInstaller.install) == "table" then
				UpdateInstaller.install:revert()
			end
			if type(NetworkFake.whenOnline) == "table" then
				NetworkFake.whenOnline:revert()
			end
		end)

		--- Answer every install with the same outcome
		-- @param ok boolean Whether it installed
		-- @param kind string|nil Which kind of failure
		local function installReturning(ok, kind)
			stub(UpdateInstaller, "install").returns(ok, kind, "detail for the log")
		end

		it("offers the reader the restart that brings the update into use", function()
			installReturning(true, nil)

			pluginWith({ path = "/plugins/crossbill.koplugin" }):installUpdate(AVAILABLE)

			assert
				.stub(UIManagerModule.askForRestart)
				.was_called_with(UIManagerModule, "Crossbill Sync 0.14.0 is installed.")
			assert.are.same({ "Installing update..." }, closedTexts())
			assert.stub(NetworkFake.disableWifiIfNeeded).was_called()
		end)

		it("hands the installer the directory KOReader loaded the plugin from", function()
			-- A reader may have renamed it, and guessing would replace the
			-- wrong thing.
			installReturning(true, nil)

			pluginWith({ path = "/plugins/renamed.koplugin" }):installUpdate(AVAILABLE)

			assert.are.equal("/plugins/renamed.koplugin", UpdateInstaller.install.calls[1].vals[1])
		end)

		it("says an unverified update apart from any other failure", function()
			installReturning(false, UpdateInstaller.UNVERIFIED)

			pluginWith({ path = "/plugins/crossbill.koplugin" }):installUpdate(AVAILABLE)

			assert.are.same({
				"Installing update...",
				"The update could not be verified and was not installed.\n\nIt was not signed by a key this plugin trusts.",
			}, shownTexts())
			assert.stub(UIManagerModule.askForRestart).was_not_called()
		end)

		it("points a failed install at the address to do it by hand", function()
			installReturning(false, UpdateInstaller.FAILED)

			pluginWith({ path = "/plugins/crossbill.koplugin" }):installUpdate(AVAILABLE)

			assert.are.same({
				"Installing update...",
				"Could not install the update.\n\nYou can download it yourself from:\n" .. AVAILABLE.release_url,
			}, shownTexts())
		end)

		it("clears the message and the WiFi when the install fails", function()
			installReturning(false, UpdateInstaller.FAILED)

			pluginWith({ path = "/plugins/crossbill.koplugin" }):installUpdate(AVAILABLE)

			assert.are.same({ "Installing update..." }, closedTexts())
			assert.stub(NetworkFake.disableWifiIfNeeded).was_called()
		end)

		it("waits for WiFi rather than installing while offline", function()
			local waiting
			stub(NetworkFake, "whenOnline").invokes(function(fn)
				waiting = fn
			end)
			installReturning(true, nil)

			pluginWith({ path = "/plugins/crossbill.koplugin" }):installUpdate(AVAILABLE)

			assert.stub(UpdateInstaller.install).was_not_called()

			waiting()

			assert.stub(UpdateInstaller.install).was_called()
		end)
	end)

	describe("the update dialog", function()
		local AVAILABLE = {
			current = "0.13.0",
			latest = "0.14.0",
			update_available = true,
			ahead = false,
			release_url = "https://example.test/releases/tag/v0.14.0",
			download_url = "https://example.test/crossbill.koplugin.zip",
			signature_url = "https://example.test/crossbill.koplugin.zip.sig",
		}

		after_each(function()
			if type(UpdateCheck.check) == "table" then
				UpdateCheck.check:revert()
			end
		end)

		it("offers to install when the release carries an archive and a signature", function()
			stub(UpdateCheck, "check").returns(true, AVAILABLE, nil)

			pluginWith({}):checkForUpdates()

			local dialog = UIManager.show.calls[#UIManager.show.calls].vals[2]
			assert.are.equal("Install", dialog.ok_text)
			assert.are.equal("Not now", dialog.cancel_text)
			assert.are.equal("function", type(dialog.ok_callback))
		end)

		it("only shows the address when the release has nothing to install from", function()
			-- A button that cannot succeed is worse than no button.
			local unsigned = {}
			for key, value in pairs(AVAILABLE) do
				unsigned[key] = value
			end
			unsigned.signature_url = nil
			stub(UpdateCheck, "check").returns(true, unsigned, nil)

			pluginWith({}):checkForUpdates()

			local shown = UIManager.show.calls[#UIManager.show.calls].vals[2]
			assert.is_nil(shown.ok_text)
			assert.is_truthy(shown.text:find(AVAILABLE.release_url, 1, true))
		end)
	end)
end)
