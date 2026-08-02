--[[
Crossbill Sync Plugin for KOReader

A plugin to synchronize book highlights with a Crossbill server.
Supports manual sync, auto-sync on suspend/exit 
]]

local WidgetContainer = require("ui/widget/container/widgetcontainer")
local Dispatcher = require("dispatcher")
local logger = require("logger")
local DataStorage = require("datastorage")
local _ = require("gettext")

local Settings = require("modules/settings")
local Network = require("modules/network")
local Auth = require("modules/auth")
local ApiClient = require("modules/api_client")
local SessionTracker = require("modules/sessiontracker")
local DigestCache = require("modules/digest_cache")
local DigestService = require("modules/digest_service")
local FileUploader = require("modules/file_uploader")
local SyncService = require("modules/sync_service")
local UI = require("modules/ui")
local BookMetadata = require("modules/book_metadata")

local CrossbillSync = WidgetContainer:extend({
	name = "Crossbill",
	is_doc_only = true, -- Only show when document is open
})

--- Register gesture-bindable actions with KOReader's Dispatcher
-- These show up in the gesture manager under "Sync current book with
-- Crossbill" and "Crossbill chapter digest".
function CrossbillSync:onDispatcherRegisterActions()
	Dispatcher:registerAction("crossbill_sync_current_book", {
		category = "none",
		event = "CrossbillSyncCurrentBook",
		title = _("Sync current book with Crossbill"),
		reader = true,
	})
	-- The action name is the key KOReader stores in a user's gesture and
	-- profile settings, and Dispatcher silently skips names it no longer
	-- knows. Renaming this to ..._digest would leave existing bindings
	-- pointing at nothing, with no error to tell the user why their gesture
	-- stopped working, so the old name stays. Only the title is user-visible.
	Dispatcher:registerAction("crossbill_show_chapter_summary", {
		category = "none",
		event = "CrossbillShowChapterDigest",
		title = _("Crossbill chapter digest"),
		reader = true,
	})
end

--- Initialize the plugin
function CrossbillSync:init()
	-- Register gesture-bindable actions
	self:onDispatcherRegisterActions()

	-- Initialize settings
	self.settings = Settings:new():load()

	-- Initialize authentication with settings
	self.auth = Auth:new(self.settings)

	-- Initialize API client with settings and auth
	self.api_client = ApiClient:new(self.settings, self.auth)

	-- Initialize file uploader with API client
	self.file_uploader = FileUploader:new(self.api_client)

	-- Initialize session tracker with settings
	self.session_tracker = SessionTracker:new(self.settings)
	self.session_tracker:init(DataStorage:getSettingsDir())

	-- Initialize digest cache (SQLite) and service
	self.digest_cache = DigestCache:new(self.settings)
	self.digest_cache:init(DataStorage:getSettingsDir())
	self.digest_service = DigestService:new(self.api_client, self.digest_cache)

	-- Initialize sync service with all dependencies
	self.sync_service =
		SyncService:new(self.api_client, self.file_uploader, self.session_tracker, self.settings, self.digest_service)

	-- Register menu
	self.ui.menu:registerToMainMenu(self)
end

--- Add plugin menu items to KOReader main menu
function CrossbillSync:addToMainMenu(menu_items)
	menu_items.crossbill_sync = UI.buildMenuItems({
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
	})
end

--- Show server configuration dialog
function CrossbillSync:configureServer()
	UI.showConfigureServerDialog(self.settings)
end

--- Show a digest result: popup on success, matching info message otherwise
-- @param item table|nil The matched digest item
-- @param err_kind string|nil The error kind returned by the digest service
function CrossbillSync:_showDigestResult(item, err_kind)
	if item then
		UI.showDigestPopup(item)
	elseif err_kind == "book_unknown" then
		UI.showDigestBookUnknown()
	elseif err_kind == "no_digest_for_book" then
		UI.showDigestEmptyBook()
	elseif err_kind == "chapter_not_matched" then
		UI.showDigestChapterNotMatched()
	else
		-- err_kind == "no_cache" (or any unexpected value)
		UI.showDigestNoCache()
	end
end

--- Show the current chapter's digest
function CrossbillSync:showChapterDigest()
	if not self.ui.document then
		logger.warn("Crossbill: Cannot show digest - no document available")
		return
	end

	local ok, book_data = pcall(function()
		return BookMetadata:new(self.ui):extractBookData()
	end)
	if not ok or not book_data or not book_data.client_book_id then
		logger.err("Crossbill: Failed to extract book metadata for the digest")
		UI.showDigestNoCache()
		return
	end

	local client_book_id = book_data.client_book_id
	local item, err_kind = self.digest_service:getForCurrentChapter(self.ui, client_book_id)

	-- Anything other than a missing cache can be shown immediately (no network needed).
	if err_kind ~= "no_cache" then
		self:_showDigestResult(item, err_kind)
		return
	end

	-- Nothing cached and the fetch failed: retry once online if WiFi is off.
	local callback = function()
		local retry_item, retry_err = self.digest_service:getForCurrentChapter(self.ui, client_book_id)
		self:_showDigestResult(retry_item, retry_err)
		Network.disableWifiIfNeeded()
	end

	if not Network.ensureWifiEnabled(callback) then
		-- WiFi is being enabled; callback will run when online
		logger.info("Crossbill: Waiting for WiFi to show digest...")
		return
	end

	-- Already online but still no cache: the fetch genuinely failed
	self:_showDigestResult(item, err_kind)
	Network.disableWifiIfNeeded()
end

--- Check if session tracking is currently active
-- @return boolean True if session tracking is enabled and tracker is available
function CrossbillSync:isSessionTrackingActive()
	return self.settings:isSessionTrackingEnabled() and self.session_tracker ~= nil
end

--- Sync the currently open book's data
-- @param is_autosync boolean If true, run in silent mode (no UI feedback)
function CrossbillSync:syncCurrentBook(is_autosync)
	local callback = function()
		self:performSync(is_autosync)
	end

	if not Network.ensureWifiEnabled(callback) then
		-- WiFi is being enabled, callback will be called when ready
		logger.info("Crossbill: Waiting for WiFi to be enabled...")
	else
		-- WiFi already on, sync immediately
		self:performSync(is_autosync)
	end
end

--- Perform the actual sync operation
-- @param is_autosync boolean If true, run in silent mode
function CrossbillSync:performSync(is_autosync)
	-- Safety check: ensure document is available
	if not self.ui.document then
		logger.warn("Crossbill: Cannot sync - no document available")
		return
	end

	if not is_autosync then
		UI.showSyncingMessage()
	end

	-- End current session before sync so it gets included
	if self:isSessionTrackingActive() and self.session_tracker:hasActiveSession() then
		self.session_tracker:endSession(self.ui.document, self.ui, "manual_sync")
	end

	local success, err = pcall(function()
		self:doSync(is_autosync)
	end)

	if not success then
		logger.err("Crossbill: Error in sync:", err)
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

--- Execute the sync workflow
-- @param is_autosync boolean If true, run in silent mode
function CrossbillSync:doSync(is_autosync)
	local result = self.sync_service:syncBook(self.ui)

	if not result.success and not is_autosync then
		if result.error and result.error:match("^Authentication") then
			UI.showAuthError(result.error)
		else
			UI.showSyncFailed(result.error)
		end
		return
	end

	-- Show success message for manual syncs
	if not is_autosync then
		UI.showSyncSuccess(result.highlights_created, result.highlights_skipped)
	end
end

-- Event handlers for gesture-bound actions (dispatched via Dispatcher)

--- Handle the "sync current book" gesture action
function CrossbillSync:onCrossbillSyncCurrentBook()
	self:syncCurrentBook()
	return true
end

--- Handle the "chapter digest" gesture action
function CrossbillSync:onCrossbillShowChapterDigest()
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
	if self:isSessionTrackingActive() then
		self.session_tracker:endSession(self.ui.document, self.ui, "suspend")
	end
	if self.settings:isAutosyncEnabled() then
		logger.info("Crossbill: Auto-syncing on suspend")
		self:syncCurrentBook(true)
	else
	end
	return false
end

--- Called when KOReader exits
function CrossbillSync:onExit()
	if self:isSessionTrackingActive() then
		self.session_tracker:endSession(self.ui.document, self.ui, "app_exit")
	end
	if self.settings:isAutosyncEnabled() then
		logger.info("Crossbill: Auto-syncing on exit")
		self:syncCurrentBook(true)
	end
	-- Close databases after sync attempts
	if self.session_tracker then
		self.session_tracker:close()
	end
	if self.digest_cache then
		self.digest_cache:close()
	end
	return false
end

return CrossbillSync
