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
function UI.showMessage(text, timeout)
	UIManager:show(InfoMessage:new({
		text = text,
		timeout = timeout,
	}))
end

--- Show a syncing in progress message
function UI.showSyncingMessage()
	UI.showMessage(_("Syncing highlights..."), 2)
end

--- Show sync success message
-- @param created number Number of new highlights
-- @param skipped number Number of duplicate highlights
function UI.showSyncSuccess(created, skipped)
	UI.showMessage(string.format(_("Synced successfully!\n%d new, %d duplicates"), created or 0, skipped or 0), 3)
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

--- Build the display title for a digest item
-- @param item table Digest item with chapter_name and parent_chapter_name
-- @return string Title, prefixed with the parent chapter name when present
local function buildDigestTitle(item)
	local chapter_name = item.chapter_name or _("Chapter")
	if item.parent_chapter_name and item.parent_chapter_name ~= "" then
		return item.parent_chapter_name .. " › " .. chapter_name
	end
	return chapter_name
end

--- Strip markdown inline markers from a text for plain-text display
-- The server's digest content contains markdown (e.g. **bold**), which
-- older TextViewers render as literal asterisks. Order matters: bold before
-- italics so ** is consumed first.
-- @param text any The raw text (non-strings pass through tostring)
-- @return string The text without markdown markers
local function stripMarkdown(text)
	local result = tostring(text)
	result = result:gsub("%*%*(.-)%*%*", "%1")
	result = result:gsub("__(.-)__", "%1")
	result = result:gsub("%*(.-)%*", "%1")
	result = result:gsub("`(.-)`", "%1")
	-- Leading heading markers at the start of any line
	result = result:gsub("^#+%s*", ""):gsub("\n#+%s*", "\n")
	return result
end

--- Escape HTML-special characters so raw content can't break the markup
-- Ampersand MUST be escaped first, otherwise the entities we introduce for
-- < and > would themselves get double-escaped.
-- @param text any The raw text (non-strings pass through tostring)
-- @return string HTML-safe text
local function escapeHtml(text)
	local result = tostring(text)
	result = result:gsub("&", "&amp;")
	result = result:gsub("<", "&lt;")
	result = result:gsub(">", "&gt;")
	return result
end

--- Convert a single line of inline markdown to HTML
-- HTML-escapes first (so content is safe), then converts markdown markers to
-- tags. Bold (**/__) is handled before italics (*) so the double markers are
-- consumed first.
-- @param text any The raw text (non-strings pass through tostring)
-- @return string HTML with inline markup applied
local function inlineMarkdownToHtml(text)
	local result = escapeHtml(text)
	result = result:gsub("%*%*(.-)%*%*", "<strong>%1</strong>")
	result = result:gsub("__(.-)__", "<strong>%1</strong>")
	result = result:gsub("%*(.-)%*", "<em>%1</em>")
	result = result:gsub("`(.-)`", "<code>%1</code>")
	return result
end

--- Build the popup body as HTML, with inline markdown rendered as tags
-- Summary paragraphs (separated by blank lines) become <p> blocks; key points
-- become a <ul>, questions an <ol>. All content flows through
-- inlineMarkdownToHtml so bold/italics/code render properly.
-- @param item table Digest item with summary, keypoints, questions
-- @return string HTML body
local function buildDigestHtml(item)
	local parts = {}

	if item.summary and item.summary ~= "" then
		-- Split the summary on blank lines into separate <p> blocks. Appending
		-- a trailing blank line lets the final paragraph match too.
		for paragraph in (tostring(item.summary) .. "\n\n"):gmatch("(.-)\n%s*\n") do
			local trimmed = paragraph:gsub("^%s+", ""):gsub("%s+$", "")
			if trimmed ~= "" then
				table.insert(parts, "<p>" .. inlineMarkdownToHtml(trimmed) .. "</p>")
			end
		end
	end

	if item.keypoints and #item.keypoints > 0 then
		table.insert(parts, "<h2>" .. escapeHtml(_("Key points")) .. "</h2>")
		local list = { "<ul>" }
		for _idx, point in ipairs(item.keypoints) do
			table.insert(list, "<li>" .. inlineMarkdownToHtml(point) .. "</li>")
		end
		table.insert(list, "</ul>")
		table.insert(parts, table.concat(list))
	end

	if item.questions and #item.questions > 0 then
		table.insert(parts, "<h2>" .. escapeHtml(_("Questions to think about")) .. "</h2>")
		local list = { "<ol>" }
		for _idx, question in ipairs(item.questions) do
			table.insert(list, "<li>" .. inlineMarkdownToHtml(question) .. "</li>")
		end
		table.insert(list, "</ol>")
		table.insert(parts, table.concat(list))
	end

	if #parts == 0 then
		return "<p>" .. escapeHtml(_("No digest available for this chapter.")) .. "</p>"
	end

	return table.concat(parts, "\n")
end

--- Build the popup body as plain text, with markdown markers stripped
-- Fallback for older TextViewers without markdown rendering.
-- @param item table Digest item with summary, keypoints, questions
-- @return string Multi-section plain text body
local function buildDigestBody(item)
	local sections = {}

	if item.summary and item.summary ~= "" then
		table.insert(sections, stripMarkdown(item.summary))
	end

	if item.keypoints and #item.keypoints > 0 then
		local lines = { _("Key points") }
		for _idx, point in ipairs(item.keypoints) do
			table.insert(lines, "• " .. stripMarkdown(point))
		end
		table.insert(sections, table.concat(lines, "\n"))
	end

	if item.questions and #item.questions > 0 then
		local lines = { _("Questions to think about") }
		for i, question in ipairs(item.questions) do
			table.insert(lines, tostring(i) .. ". " .. stripMarkdown(question))
		end
		table.insert(sections, table.concat(lines, "\n"))
	end

	if #sections == 0 then
		return _("No digest available for this chapter.")
	end

	return table.concat(sections, "\n\n")
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
				title = buildDigestTitle(item),
				html = buildDigestHtml(item),
			}))
		end)
		if ok then
			return
		end
		logger.warn("Crossbill: digest HTML viewer failed, using plain text: " .. tostring(err))
	end

	UIManager:show(TextViewer:new({
		title = buildDigestTitle(item),
		text = buildDigestBody(item),
	}))
end

--- Show a message when no digest is cached and we are offline
function UI.showDigestNoCache()
	UI.showMessage(_("No digest cached yet. Sync this book while online."), 4)
end

--- Show a message when the book is unknown to the server
function UI.showDigestBookUnknown()
	UI.showMessage(_("Book not found on Crossbill. Sync this book first."), 4)
end

--- Show a message when the book is known but has no digest generated
function UI.showDigestEmptyBook()
	UI.showMessage(_("No digest generated for this book yet. Generate it in the Crossbill web app."), 4)
end

--- Show a message when the current chapter could not be matched
function UI.showDigestChapterNotMatched()
	UI.showMessage(_("Couldn't match the current chapter to Crossbill's chapter list."), 4)
end

--- Show server configuration dialog
-- @param settings Settings instance
-- @param on_save function Callback when settings are saved
function UI.showConfigureServerDialog(settings, on_save)
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

						if on_save then
							on_save()
						end
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
-- @param on_save function Callback when settings are saved
function UI.showMinSessionDurationDialog(settings, on_save)
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
							settings:set("min_reading_session_duration", duration)
							settings:save()
							UIManager:close(dialog)
							UI.showSettingsSaved()

							if on_save then
								on_save()
							end
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
		},
	}
end

return UI
