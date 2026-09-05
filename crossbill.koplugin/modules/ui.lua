--[[
UI Module for Crossbill Sync

Provides UI components for the plugin including:
- Information messages and notifications
- Server configuration dialog
- Menu structure
]]

local UIManager = require("ui/uimanager")
local InfoMessage = require("ui/widget/infomessage")
local MultiInputDialog = require("ui/widget/multiinputdialog")
local TextViewer = require("ui/widget/textviewer")
local ConfirmBox = require("ui/widget/confirmbox")
local Trapper = require("ui/trapper")
local DigestFormat = require("modules/digest_format")
local UpgradeRequired = require("modules/upgrade_required")
local meta = require("_meta")
local logger = require("logger")
local _ = require("gettext")

-- The rich HTML viewer pulls in several KOReader widgets. On an exotic build
-- where one of those requires is unavailable, we fall back to a plain-text
-- TextViewer, so load it protectively and treat a failure as "not available".
local ok_viewer, DigestViewer = pcall(function()
	return require("modules/digest_viewer")
end)
if not ok_viewer then
	logger.warn("Crossbill: digest HTML viewer unavailable: " .. tostring(DigestViewer))
	DigestViewer = nil
end

local UI = {}

--- Show an informational message to the user
-- @param text string The message to display
-- @param timeout number|nil Auto-dismiss timeout in seconds (nil = no auto-dismiss)
-- @return table The widget now on screen, for a caller that may dismiss it early
function UI.showMessage(text, timeout)
	local message = InfoMessage:new({
		text = text,
		timeout = timeout,
	})
	UIManager:show(message)
	return message
end

--- Take a message this module put on screen back down
-- @param widget table|nil A widget an earlier show returned, nil to do nothing
function UI.dismiss(widget)
	if not widget then
		return
	end

	UIManager:close(widget)
end

--- Show a syncing in progress message
-- @return table The message widget, for a sync that ends before its timeout
function UI.showSyncingMessage()
	return UI.showMessage(_("Syncing with Crossbill..."), 2)
end

--- Show the outcome of a sync: what was uploaded, and what the pull brought back
-- @param result table Sync result with the upload counts and the pull outcome
function UI.showSyncSuccess(result)
	local lines = {}

	local uploaded = result.highlights_created or 0
	if uploaded > 0 then
		table.insert(lines, string.format(_("Uploaded %d new highlights."), uploaded))
	end

	local removed = result.highlights_removed or 0
	if removed > 0 then
		table.insert(lines, string.format(_("%d removed from your devices."), removed))
	end

	local pull = result.pull or {}
	local pulled = pull.inserted or 0
	if pulled > 0 then
		table.insert(lines, string.format(_("Pulled %d highlights from Crossbill."), pulled))
	end

	local skipped = (pull.skipped_unplaceable or 0) + (pull.skipped_invalid or 0)
	if skipped > 0 then
		table.insert(lines, string.format(_("Skipped: %d"), skipped))
	end

	if result.pull_error then
		table.insert(lines, _("Pull failed: ") .. tostring(result.pull_error))
	end

	if #lines == 0 then
		table.insert(lines, _("Highlights are up to date."))
	end

	UI.showMessage(table.concat(lines, "\n"), 6)
end

--- Ask before a book's whole highlight set leaves the reader's devices
-- Only ever asked when every highlight the device last pulled has gone at once,
-- which is as much the signature of a lost sidecar or of a second copy of the
-- book as of a deliberate clear-out, so the question is worth the
-- interruption. It blocks, which a ConfirmBox can only do inside a
-- Trapper coroutine; without one Trapper answers "OK" by itself, so an
-- unwrapped caller is refused rather than silently agreed with.
-- @param count number How many highlights would be removed
-- @return boolean True when the reader confirmed the removal
function UI.confirmRemoveAll(count)
	if not coroutine.running() then
		logger.warn("Crossbill: Cannot ask about removing highlights outside a Trapper coroutine")
		return false
	end

	local confirmed = Trapper:confirm(
		string.format(_("Remove all %d highlights of this book from your devices?"), count),
		_("Keep"),
		_("Remove")
	)
	return confirmed == true
end

--- Show sync error message
-- @param error_msg string The error message
function UI.showSyncError(error_msg)
	UI.showMessage(_("Sync error: ") .. tostring(error_msg), 5)
end

--- Show sync failed message
-- @param code number|string The error code
function UI.showSyncFailed(code)
	UI.showMessage(_("Sync failed: ") .. tostring(code or "unknown error"), 3)
end

--- Tell the reader the server has turned this plugin away as too old
-- A plain message with nothing to answer: a sync can be running while the book
-- or the device is closing, where a dialog awaiting dismissal would hold that
-- up. It stays on screen long enough to read an address off it.
-- @param err table|nil The refusal, or nil when there is nothing to go on
function UI.showUpgradeRequired(err)
	UI.showMessage(UpgradeRequired.message(err), 10)
end

--- Show authentication error message
-- @param error_msg string The error message
function UI.showAuthError(error_msg)
	UI.showMessage(_("Authentication failed: ") .. (error_msg or "unknown error"), 5)
end

--- Show settings saved message
function UI.showSettingsSaved()
	UI.showMessage(_("Settings saved"))
end

--- Show autosync status change message
-- @param enabled boolean Whether autosync is now enabled
function UI.showAutosyncToggled(enabled)
	UI.showMessage(enabled and _("Auto-sync enabled") or _("Auto-sync disabled"))
end

--- Show session tracking status change message
-- @param enabled boolean Whether session tracking is now enabled
function UI.showSessionTrackingToggled(enabled)
	UI.showMessage(enabled and _("Session tracking enabled") or _("Session tracking disabled"))
end

--- Show the digest popup for a matched chapter item
-- Renders the body as rich HTML (bold, headings, lists) via our own
-- ScrollHtmlWidget-based viewer. If that viewer is unavailable or fails to
-- construct on some exotic build, falls back to a plain-text TextViewer with
-- markdown markers stripped.
-- @param item table Digest item to display
function UI.showDigestPopup(item)
	if DigestViewer then
		local ok, err = pcall(function()
			UIManager:show(DigestViewer:new({
				title = DigestFormat.title(item),
				html = DigestFormat.html(item),
			}))
		end)
		if ok then
			return
		end
		logger.warn("Crossbill: digest HTML viewer failed, using plain text: " .. tostring(err))
	end

	UIManager:show(TextViewer:new({
		title = DigestFormat.title(item),
		text = DigestFormat.plainText(item),
	}))
end

-- What each digest error kind is told to the reader. The kinds are the ones
-- modules/digest_service.lua documents; the refusal needs the error itself, so
-- it is a function where the rest are plain strings.
local DIGEST_ERROR_MESSAGES = {
	no_cache = _("No digest cached yet. Sync this book while online."),
	book_unknown = _("Book not found on Crossbill. Sync this book first."),
	no_digest_for_book = _("No digest generated for this book yet. Generate it in the Crossbill web app."),
	chapter_not_matched = _("Couldn't match the current chapter to Crossbill's chapter list."),
	[UpgradeRequired.KIND] = function(err)
		-- The digest is beside the point: nothing is served to this plugin
		-- until it is updated.
		UI.showUpgradeRequired(err)
	end,
}

--- Tell the reader why there is no digest to show
-- An unrecognised kind, or none at all, is reported as a missing cache: that is
-- the one a reader can act on, and the others are all rarer.
-- @param err_kind string|nil The error kind returned by the digest service
-- @param err table|nil The refusal, when that is the error kind
function UI.showDigestError(err_kind, err)
	local message = DIGEST_ERROR_MESSAGES[err_kind]
	if type(message) == "function" then
		message(err)
		return
	end

	UI.showMessage(message or DIGEST_ERROR_MESSAGES.no_cache, 4)
end

--- Show server configuration dialog
-- @param settings Settings instance
function UI.showConfigureServerDialog(settings)
	local dialog
	dialog = MultiInputDialog:new({
		title = _("Crossbill Settings"),
		fields = {
			{
				text = settings:getBaseUrl() or "",
				hint = _("Server URL (e.g., https://example.com)"),
			},
			{
				text = settings:getUsername() or "",
				hint = _("Username"),
			},
			{
				text = settings:getPassword() or "",
				hint = _("Password"),
				text_type = "password",
			},
		},
		buttons = {
			{
				{
					text = _("Cancel"),
					callback = function()
						UIManager:close(dialog)
					end,
				},
				{
					text = _("Save"),
					is_enter_default = true,
					callback = function()
						local fields = dialog:getFields()
						local base_url = fields[1]
						local username = fields[2]
						local password = fields[3]

						settings:updateServerConfig(base_url, username, password)
						UIManager:close(dialog)
						UI.showSettingsSaved()
					end,
				},
			},
		},
	})

	UIManager:show(dialog)
	dialog:onShowKeyboard()
end

--- Show minimum reading session duration configuration dialog
-- @param settings Settings instance
function UI.showMinSessionDurationDialog(settings)
	local dialog
	dialog = MultiInputDialog:new({
		title = _("Minimum Reading Session Duration"),
		fields = {
			{
				text = tostring(settings:getMinReadingSessionDuration() or 60),
				hint = _("Duration in seconds (e.g., 60)"),
				input_type = "number",
			},
		},
		buttons = {
			{
				{
					text = _("Cancel"),
					callback = function()
						UIManager:close(dialog)
					end,
				},
				{
					text = _("Save"),
					is_enter_default = true,
					callback = function()
						local fields = dialog:getFields()
						local duration = tonumber(fields[1])

						if duration and duration > 0 then
							settings:setMinReadingSessionDuration(duration)
							UIManager:close(dialog)
							UI.showSettingsSaved()
						else
							UI.showMessage(_("Invalid duration. Please enter a number greater than 0."), 3)
						end
					end,
				},
			},
		},
	})

	UIManager:show(dialog)
	dialog:onShowKeyboard()
end

--- Show what this plugin is and where it comes from
-- Name and version are read from `_meta.lua` rather than written out here, so
-- the side-by-side test build names itself and the version can never go stale.
-- The address is shown as text: a reader on an e-ink device copies it by hand.
function UI.showAbout()
	local lines = {
		meta.fullname,
		string.format(_("Version %s"), tostring(meta.version)),
		"",
		_("Source code and issues:"),
		meta.homepage,
	}

	UI.showMessage(table.concat(lines, "\n"))
end

--- Tell the reader the update check is under way
-- No timeout: a request can outlast any guess at one, and unlike a sync there
-- is nothing else on screen to say work is happening. The caller takes the
-- message back down on every path out.
-- @return table The message widget, for the caller to dismiss
function UI.showUpdateChecking()
	local message = UI.showMessage(_("Checking for updates..."))
	-- The check blocks the same tick that showed this, so without a repaint
	-- here the reader would see nothing at all until the result arrives.
	UIManager:forceRePaint()
	return message
end

--- Tell the reader a newer version has been published
-- Offered as a question only when the release carries both the archive and the
-- signature: a button that cannot succeed is worse than no button. Otherwise
-- the address is shown as text, for a reader to copy by hand as About's is.
-- @param result table The check result
-- @param on_install function|nil Called when the reader asks to install
function UI.showUpdateAvailable(result, on_install)
	local lines = {
		string.format(_("%s %s is available."), meta.fullname, result.latest),
		string.format(_("You have %s."), result.current),
	}

	if on_install and result.download_url and result.signature_url then
		UIManager:show(ConfirmBox:new({
			text = table.concat(lines, "\n"),
			ok_text = _("Install"),
			ok_callback = on_install,
			cancel_text = _("Not now"),
		}))
		return
	end

	table.insert(lines, "")
	table.insert(lines, _("Download:"))
	table.insert(lines, result.release_url)
	UI.showMessage(table.concat(lines, "\n"), 10)
end

--- Tell the reader the update is being fetched and put in place
-- No timeout, and taken down by the caller on every path out, as the check's
-- message is: several blocking steps run behind it.
-- @return table The message widget, for the caller to dismiss
function UI.showInstallingUpdate()
	local message = UI.showMessage(_("Installing update..."))
	UIManager:forceRePaint()
	return message
end

--- Tell the reader the update is in place, and offer the restart it needs
-- `askForRestart` is KOReader's own: it asks where restarting is possible and
-- says the update waits for the next start where it is not, which is a
-- per-platform judgement the plugin has no business making. It does nothing at
-- all when the device's event handlers were never installed, though -- its own
-- source only says they "should always exist" -- and a reader who is told
-- nothing after an install has no way of knowing it worked. So the message is
-- shown here in the one case KOReader would swallow it.
-- @param version string The version now installed
function UI.showUpdateInstalled(version)
	local text = string.format(_("%s %s is installed."), meta.fullname, version)

	if UIManager.event_handlers and UIManager.event_handlers.PowerOff then
		UIManager:askForRestart(text)
		return
	end

	UI.showMessage(text, 10)
end

--- Tell the reader the update could not be installed
-- One message for every way of failing except one, and it carries the address
-- so the reader can do by hand what the plugin would not do for them.
-- @param result table The check result, for the address
function UI.showInstallFailed(result)
	local lines = {
		_("Could not install the update."),
		"",
		_("You can download it yourself from:"),
		result and result.release_url or meta.homepage,
	}

	UI.showMessage(table.concat(lines, "\n"), 10)
end

--- Tell the reader the update was not signed by a key the plugin trusts
-- Said apart from every other failure on purpose. The others mean something
-- went wrong; this one means the archive is not what it claims to be, and a
-- reader deciding whether to install it by hand should know which they have.
function UI.showInstallUnverified()
	local lines = {
		_("The update could not be verified and was not installed."),
		"",
		_("It was not signed by a key this plugin trusts."),
	}

	UI.showMessage(table.concat(lines, "\n"), 10)
end

--- Tell the reader there is nothing to update to
-- A plugin ahead of the newest release is not up to date, so it is told what it
-- is running and what was published rather than being reassured.
-- @param result table The check result
function UI.showNoUpdate(result)
	if result.ahead then
		local lines = {
			string.format(_("You are running %s."), result.current),
			string.format(_("The latest release is %s."), result.latest),
		}
		UI.showMessage(table.concat(lines, "\n"), 5)
		return
	end

	UI.showMessage(string.format(_("%s %s is the latest version."), meta.fullname, result.current), 3)
end

--- Tell the reader the check did not complete
-- One message for every failure: nothing a reader could do differs between
-- being offline, being rate limited and a release that will not parse, and what
-- tells those apart is in the log.
function UI.showUpdateCheckFailed()
	UI.showMessage(_("Could not check for updates. Please try again later."), 5)
end

--- Build the main menu structure for the plugin
-- Primary actions (sync, chapter digest) are top-level; everything else
-- lives under a Settings submenu.
-- @param handlers table Callback handlers for menu actions
--   - on_sync: function() Called when sync is triggered
--   - on_show_digest: function() Called when the chapter digest is requested
--   - on_configure: function() Called when configure is triggered
--   - is_autosync_enabled: function() Returns autosync state
--   - on_toggle_autosync: function() Called when autosync is toggled
--   - is_session_tracking_enabled: function() Returns session tracking state
--   - on_toggle_session_tracking: function() Called when session tracking is toggled
--   - on_configure_min_session_duration: function() Called when min session duration is configured
--   - on_check_for_updates: function() Called when an update check is requested
-- @return table Menu item table for KOReader
function UI.buildMenuItems(handlers)
	return {
		text = _("Crossbill"),
		sorting_hint = "tools",
		sub_item_table = {
			{
				text = _("Sync Current Book"),
				callback = handlers.on_sync,
			},
			{
				text = _("Chapter digest"),
				callback = handlers.on_show_digest,
			},
			{
				text = _("Settings"),
				sub_item_table = {
					{
						text = _("Configure Server"),
						callback = handlers.on_configure,
					},
					{
						text = _("Auto-sync"),
						checked_func = handlers.is_autosync_enabled,
						callback = handlers.on_toggle_autosync,
					},
					{
						text = _("Track Reading Sessions"),
						checked_func = handlers.is_session_tracking_enabled,
						callback = handlers.on_toggle_session_tracking,
					},
					{
						text = _("Minimum Session Duration"),
						callback = handlers.on_configure_min_session_duration,
					},
				},
			},
			{
				-- Beside About, which is where the running version is shown.
				-- The menu closes behind it: the check may put a WiFi prompt
				-- and then a result on screen seconds apart.
				text = _("Check for Updates"),
				callback = handlers.on_check_for_updates,
			},
			{
				text = _("About"),
				keep_menu_open = true,
				callback = UI.showAbout,
			},
		},
	}
end

return UI
