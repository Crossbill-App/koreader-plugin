--[[
Crossbill Sync Plugin for KOReader

A plugin to synchronize book highlights with a Crossbill server.
Supports manual sync, auto-sync on suspend/exit
]]

local WidgetContainer = require("ui/widget/container/widgetcontainer")
local Dispatcher = require("dispatcher")
local DataStorage = require("datastorage")
local Trapper = require("ui/trapper")
local T = require("ffi/util").template
local _ = require("gettext")

local Log = require("modules/log")
local log = Log.forModule("Main")
local PluginIdentity = require("modules/plugin_identity")
local Settings = require("modules/settings")
local Network = require("modules/network")
local Auth = require("modules/auth")
local AuthFailed = require("modules/auth_failed")
local ApiClient = require("modules/api_client")
local SessionTracker = require("modules/sessiontracker")
local SessionStore = require("modules/session_store")
local DigestCache = require("modules/digest_cache")
local DigestService = require("modules/digest_service")
local HighlightImporter = require("modules/highlight_importer")
local HighlightSnapshot = require("modules/highlight_snapshot")
local HighlightSnapshotStore = require("modules/highlight_snapshot_store")
local LegacyDatabases = require("modules/legacy_databases")
local SqliteStore = require("modules/sqlite_store")
local SyncService = require("modules/sync_service")
local UI = require("modules/ui")
local BookMetadata = require("modules/book_metadata")
local DocumentSupport = require("modules/document_support")
local UpdateCheck = require("modules/update/check")
local UpdateInstaller = require("modules/update/installer")

-- The plugin's own names for the things KOReader keys by: the menu entry, the
-- two gesture-bindable actions and the two events they dispatch. All of them
-- come from the plugin's name, so the side-by-side test build gets its own set
-- rather than seizing the production plugin's; see modules/plugin_identity.lua.
local MENU_KEY = PluginIdentity.namespace .. "_sync"
local ACTION_SYNC = PluginIdentity.namespace .. "_sync_current_book"
-- The action name is the key KOReader stores in a user's gesture and profile
-- settings, and Dispatcher silently skips names it no longer knows. Renaming
-- this to ..._digest would leave existing bindings pointing at nothing, with no
-- error to tell the user why their gesture stopped working, so the old name
-- stays. Only the title is user-visible.
local ACTION_DIGEST = PluginIdentity.namespace .. "_show_chapter_summary"
local EVENT_SYNC = PluginIdentity.event_prefix .. "SyncCurrentBook"
local EVENT_DIGEST = PluginIdentity.event_prefix .. "ShowChapterDigest"

local CrossbillSync = WidgetContainer:extend({
	name = PluginIdentity.display_name,
	is_doc_only = true, -- Only show when document is open
})

--- Register gesture-bindable actions with KOReader's Dispatcher
-- These show up in the gesture manager under "Sync current book with
-- Crossbill" and "Crossbill chapter digest".
function CrossbillSync:onDispatcherRegisterActions()
	Dispatcher:registerAction(ACTION_SYNC, {
		category = "none",
		event = EVENT_SYNC,
		title = T(_("Sync current book with %1"), PluginIdentity.display_name),
		reader = true,
	})
	Dispatcher:registerAction(ACTION_DIGEST, {
		category = "none",
		event = EVENT_DIGEST,
		title = T(_("%1 chapter digest"), PluginIdentity.display_name),
		reader = true,
	})
end

--- Initialize the plugin
-- Everything below the document check is skipped on a non-EPUB: no menu, no
-- databases, no session. The gesture actions are registered first regardless,
-- because they are global configuration -- a reader must be able to bind the
-- gesture while a PDF happens to be open, even though it will do nothing here.
function CrossbillSync:init()
	-- Register gesture-bindable actions
	self:onDispatcherRegisterActions()

	self.is_supported_document = DocumentSupport.isSupportedDocument(self.ui)
	if not self.is_supported_document then
		log.info("Not an EPUB, plugin stays inactive for this document")
		return
	end

	-- Initialize settings
	self.settings = Settings:new():load()

	-- Initialize authentication with settings
	self.auth = Auth:new(self.settings)

	-- Initialize API client with settings and auth
	self.api_client = ApiClient:new(self.settings, self.auth)

	-- One SQLite file for everything the plugin keeps, opened here and shared
	-- by the three stores below, each of which asks it for its own tables. A
	-- file that will not open leaves those stores unprepared, which is how they
	-- already answer a database that is not there: nothing is written, nothing
	-- is read, and the sync carries on without them.
	local settings_dir = DataStorage:getSettingsDir()
	self.database = SqliteStore:new()
	self.database:open(settings_dir .. "/" .. PluginIdentity.database_filename)

	-- Initialize the session tracker over its tables in that database
	self.session_tracker = SessionTracker:new({ settings = self.settings, store = SessionStore:new(self.database) })
	self.session_tracker:init()

	-- Initialize digest cache and service
	self.digest_cache = DigestCache:new(self.database)
	self.digest_cache:prepare()
	self.digest_service = DigestService:new(self.api_client, self.digest_cache)

	-- Initialize the importer that writes pulled highlights back to the book
	self.highlight_importer = HighlightImporter:new()

	-- Initialize the ledger of the server highlights last applied
	self.highlight_snapshot = HighlightSnapshot:new({ store = HighlightSnapshotStore:new(self.database) })
	self.highlight_snapshot:init()

	-- With every table now made, carry over whatever a reader still has in the
	-- three databases the plugin kept before this one, and remove them.
	LegacyDatabases.absorb(self.database, settings_dir)

	-- Initialize sync service with all dependencies
	self.sync_service = SyncService:new({
		api_client = self.api_client,
		session_tracker = self.session_tracker,
		settings = self.settings,
		digest_service = self.digest_service,
		highlight_importer = self.highlight_importer,
		highlight_snapshot = self.highlight_snapshot,
	})

	-- Register menu
	self.ui.menu:registerToMainMenu(self)
end

--- Add plugin menu items to KOReader main menu
function CrossbillSync:addToMainMenu(menu_items)
	menu_items[MENU_KEY] = UI.buildMenuItems({
		on_sync = function()
			self:syncCurrentBook()
		end,
		on_show_digest = function()
			self:showChapterDigest()
		end,
		on_configure = function()
			self:configureServer()
		end,
		is_autosync_enabled = function()
			return self.settings:isAutosyncEnabled()
		end,
		on_toggle_autosync = function()
			local enabled = self.settings:toggleAutosync()
			UI.showAutosyncToggled(enabled)
		end,
		is_session_tracking_enabled = function()
			return self.settings:isSessionTrackingEnabled()
		end,
		on_toggle_session_tracking = function()
			-- End current session before disabling tracking
			if self:isSessionTrackingActive() then
				self.session_tracker:endSession(self.ui.document, self.ui, "tracking_disabled")
			end
			local enabled = self.settings:toggleSessionTracking()
			UI.showSessionTrackingToggled(enabled)
			-- Start new session if re-enabled and document is open
			if enabled and self.ui.document and self.session_tracker then
				self.session_tracker:startSession(self.ui.document, self.ui)
			end
		end,
		on_configure_min_session_duration = function()
			UI.showMinSessionDurationDialog(self.settings)
		end,
		on_check_for_updates = function()
			self:checkForUpdates()
		end,
	})
end

--- Find out whether a newer plugin version has been published
-- WiFi is turned on if it is off, the check runs once the device is online, and
-- WiFi goes back off afterwards if the plugin was the one that turned it on.
function CrossbillSync:checkForUpdates()
	Network.whenOnline(function()
		self:_updateCheck()
	end)
end

--- Ask what the newest release is and report what came back
-- The "checking" message has no timeout, so it and the WiFi are both cleared
-- here, before anything else can return.
function CrossbillSync:_updateCheck()
	local checking = UI.showUpdateChecking()

	local completed, result, err = UpdateCheck.check()

	UI.dismiss(checking)
	Network.disableWifiIfNeeded()

	if not completed then
		-- The reader is told one thing whatever went wrong; this is where the
		-- difference is kept.
		log.err("Update check failed:", tostring(err))
		UI.showUpdateCheckFailed()
		return
	end

	if not result.update_available then
		UI.showNoUpdate(result)
		return
	end

	UI.showUpdateAvailable(result, function()
		self:installUpdate(result)
	end)
end

--- Fetch the release the check found and put it in the plugin's place
-- WiFi again rather than still: the check turned it back off before the reader
-- was asked anything, and a reader who thinks it over for a minute should not
-- find the answer has expired.
-- @param result table The check result, carrying the archive and its signature
function CrossbillSync:installUpdate(result)
	Network.whenOnline(function()
		self:_install(result)
	end)
end

--- Install the update and ask for the restart that brings it into use
-- `self.path` is where KOReader loaded this plugin from, which is the only
-- honest answer to what should be replaced: a reader may have renamed it, and
-- the installer refuses rather than guessing when the archive does not match.
-- @param result table The check result
function CrossbillSync:_install(result)
	local installing = UI.showInstallingUpdate()

	local ok, kind, detail = UpdateInstaller.install(self.path, result)

	UI.dismiss(installing)
	Network.disableWifiIfNeeded()

	if ok then
		UI.showUpdateInstalled(result.latest)
		return
	end

	log.err("Update install failed:", tostring(detail))

	if kind == UpdateInstaller.UNVERIFIED then
		UI.showInstallUnverified()
	else
		UI.showInstallFailed(result)
	end
end

--- Show server configuration dialog
function CrossbillSync:configureServer()
	UI.showConfigureServerDialog(self.settings)
end

--- Show a digest result: popup on success, matching info message otherwise
-- @param item table|nil The matched digest item
-- @param err_kind string|nil The error kind returned by the digest service
-- @param err table|nil The refusal, when that is the error kind
function CrossbillSync:_showDigestResult(item, err_kind, err)
	if item then
		UI.showDigestPopup(item)
		return
	end

	UI.showDigestError(err_kind, err)
end

--- Show the current chapter's digest
function CrossbillSync:showChapterDigest()
	if not self.is_supported_document then
		log.warn("Cannot show digest - the open document is not an EPUB")
		return
	end

	if not self.ui.document then
		log.warn("Cannot show digest - no document available")
		return
	end

	local ok, book_data = pcall(function()
		return BookMetadata:new(self.ui):extractBookData()
	end)
	if not ok or not book_data or not book_data.client_book_id then
		log.err("Failed to extract book metadata for the digest")
		UI.showDigestError("no_cache")
		return
	end

	local client_book_id = book_data.client_book_id
	local item, err_kind, err = self.digest_service:getForCurrentChapter(self.ui, client_book_id)

	-- Anything other than a missing cache can be shown immediately (no network
	-- needed), and so can a missing cache on a device that is already online:
	-- the fetch that just failed would only fail the same way again.
	if err_kind ~= "no_cache" or Network.isConnected() then
		self:_showDigestResult(item, err_kind, err)
		return
	end

	-- Nothing cached and no connection to fetch one over: ask for WiFi and try
	-- the once more that is worth trying.
	Network.whenOnline(function()
		local retry_item, retry_err_kind, retry_err = self.digest_service:getForCurrentChapter(self.ui, client_book_id)
		self:_showDigestResult(retry_item, retry_err_kind, retry_err)
		Network.disableWifiIfNeeded()
	end)
end

--- Check if session tracking is currently active
-- @return boolean True if session tracking is enabled and tracker is available
function CrossbillSync:isSessionTrackingActive()
	return self.is_supported_document and self.settings:isSessionTrackingEnabled() and self.session_tracker ~= nil
end

--- Sync the currently open book's data
-- @param is_autosync boolean If true, run in silent mode (no UI feedback)
function CrossbillSync:syncCurrentBook(is_autosync)
	if not self.is_supported_document then
		log.warn("Cannot sync - the open document is not an EPUB")
		return
	end

	Network.whenOnline(function()
		self:_runSync(is_autosync)
	end)
end

--- Run one sync from start to finish, including what has to follow it
-- @param is_autosync boolean If true, run in silent mode
function CrossbillSync:_runSync(is_autosync)
	-- Safety check: ensure document is available
	if not self.ui.document then
		log.warn("Cannot sync - no document available")
		return
	end

	local sync = function()
		if not is_autosync then
			self.syncing_message = UI.showSyncingMessage()
		end

		-- End current session before sync so it gets included
		if self:isSessionTrackingActive() and self.session_tracker:hasActiveSession() then
			self.session_tracker:endSession(self.ui.document, self.ui, "manual_sync")
		end

		local success, err = pcall(function()
			self:doSync(is_autosync)
		end)

		-- Past this point the message is the timeout's to clear, not the sync's.
		self.syncing_message = nil

		if not success then
			log.err("Error in sync:", err)
			if not is_autosync then
				UI.showSyncError(err)
			end
		end

		-- Restart session after sync so reading continues to be tracked
		if self:isSessionTrackingActive() and self.ui.document then
			self.session_tracker:startSession(self.ui.document, self.ui)
		end

		-- Always clean up WiFi after sync
		Network.disableWifiIfNeeded()
	end

	if is_autosync then
		-- An autosync runs while the book is being torn down and has nobody to
		-- put a question to, so it stays a plain call that never blocks.
		sync()
		return
	end

	-- A manual sync may have to ask before withdrawing highlights from the
	-- reader's other devices, and a ConfirmBox can only block inside a Trapper
	-- coroutine. Everything after the question -- the summary, the restarted
	-- session, the WiFi cleanup -- has to resume in that same coroutine, so the
	-- whole sync goes inside the wrapper rather than just the dialog.
	Trapper:wrap(sync)
end

--- Tell the reader the server has turned this plugin away
-- A manual sync's "Syncing..." message clears on a timeout rather than when the
-- sync ends, so it has to come down before the refusal replaces it.
-- @param err table The server's refusal
function CrossbillSync:_reportUpgradeRequired(err)
	UI.dismiss(self.syncing_message)
	self.syncing_message = nil
	UI.showUpgradeRequired(err)
end

--- Execute the sync workflow
-- @param is_autosync boolean If true, run in silent mode
function CrossbillSync:doSync(is_autosync)
	local result = self.sync_service:syncBook(self.ui, {
		-- Only a manual sync has a reader in front of it to answer.
		confirm_removal = (not is_autosync) and UI.confirmRemoveAll or nil,
		-- An autosync says it too: one that has quietly stopped working is
		-- exactly what a reader needs told about.
		on_upgrade_required = function(err)
			self:_reportUpgradeRequired(err)
		end,
	})

	if result.upgrade_required then
		-- The refusal is the one message this attempt gets.
		return
	end

	if not result.success and not is_autosync then
		-- Which dialog this is depends on the kind of failure, not on how the
		-- message reads: the reader whose password is wrong needs sending to the
		-- settings, and everyone else does not.
		if AuthFailed.is(result.error) then
			UI.showAuthError(result.error)
		else
			UI.showSyncFailed(result.error)
		end
		return
	end

	-- Show success message for manual syncs
	if not is_autosync then
		UI.showSyncSuccess(result)
	end
end

-- Event handlers for gesture-bound actions (dispatched via Dispatcher)
--
-- KOReader dispatches an event by calling the method named "on" .. event, so
-- these two are assigned under the derived names rather than written out as
-- `function CrossbillSync:onCrossbillSyncCurrentBook()`. Spelling them out
-- would leave the test build registering CrossbillTestSyncCurrentBook and
-- answering only to CrossbillSyncCurrentBook -- a gesture that does nothing,
-- with nothing anywhere to say why.

--- Handle the "sync current book" gesture action
CrossbillSync["on" .. EVENT_SYNC] = function(self)
	self:syncCurrentBook()
	return true
end

--- Handle the "chapter digest" gesture action
CrossbillSync["on" .. EVENT_DIGEST] = function(self)
	self:showChapterDigest()
	return true
end

-- Event handlers for session tracking and auto-sync

--- Called when document is ready for reading
function CrossbillSync:onReaderReady()
	if self:isSessionTrackingActive() then
		self.session_tracker:startSession(self.ui.document, self.ui)
	end
	return false
end

--- Called on every page update
function CrossbillSync:onPageUpdate(pageno)
	if self:isSessionTrackingActive() then
		self.session_tracker:updatePosition(self.ui.document, self.ui, pageno)
	end
	return false
end

--- Called when device resumes from sleep
function CrossbillSync:onResume()
	if self:isSessionTrackingActive() and self.ui.document then
		self.session_tracker:startSession(self.ui.document, self.ui)
	end
	return false
end

--- Called when document is closed
function CrossbillSync:onCloseDocument()
	if self:isSessionTrackingActive() then
		self.session_tracker:endSession(self.ui.document, self.ui, "document_close")
	end
	return false
end

--- Called when device goes to sleep/suspend
function CrossbillSync:onSuspend()
	if not self.is_supported_document then
		return false
	end
	if self:isSessionTrackingActive() then
		self.session_tracker:endSession(self.ui.document, self.ui, "suspend")
	end
	if self.settings:isAutosyncEnabled() then
		log.info("Auto-syncing on suspend")
		self:syncCurrentBook(true)
	end
	return false
end

--- Called when KOReader exits
function CrossbillSync:onExit()
	if not self.is_supported_document then
		return false
	end
	if self:isSessionTrackingActive() then
		self.session_tracker:endSession(self.ui.document, self.ui, "app_exit")
	end
	if self.settings:isAutosyncEnabled() then
		log.info("Auto-syncing on exit")
		self:syncCurrentBook(true)
	end
	-- The stores let go of the database first, then it is closed -- after the
	-- sync attempts above, which were still reading from it.
	if self.session_tracker then
		self.session_tracker:close()
	end
	if self.highlight_snapshot then
		self.highlight_snapshot:close()
	end
	if self.database then
		self.database:close()
	end
	return false
end

return CrossbillSync
