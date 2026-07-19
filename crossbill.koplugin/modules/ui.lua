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
local _ = require("gettext")

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

--- Build the display title for a prereading item
-- @param item table Prereading item with chapter_name and parent_chapter_name
-- @return string Title, prefixed with the parent chapter name when present
local function buildPrereadingTitle(item)
	local chapter_name = item.chapter_name or _("Chapter")
	if item.parent_chapter_name and item.parent_chapter_name ~= "" then
		return item.parent_chapter_name .. " › " .. chapter_name
	end
	return chapter_name
end

--- Strip markdown inline markers from a text for plain-text display
-- The server's prereading content contains markdown (e.g. **bold**), which
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

--- Check whether this KOReader's TextViewer can render markdown as HTML
-- Newer TextViewers accept text_format = "md" and render via ScrollHtmlWidget;
-- older ones lack html_text_formats entirely and show plain text only.
-- @return boolean True if markdown rendering is available
local function supportsMarkdown()
	return type(TextViewer.html_text_formats) == "table" and TextViewer.html_text_formats.md == true
end

--- Build the popup body as markdown (rendered as HTML by newer TextViewers)
-- Summary, keypoints and questions are passed through verbatim so their own
-- inline markdown (bold, italics) renders properly.
-- @param item table Prereading item with summary, keypoints, questions
-- @return string Markdown body
local function buildPrereadingMarkdown(item)
	local sections = {}

	if item.summary and item.summary ~= "" then
		table.insert(sections, tostring(item.summary))
	end

	if item.keypoints and #item.keypoints > 0 then
		local lines = { "## " .. _("Key points") }
		for _idx, point in ipairs(item.keypoints) do
			table.insert(lines, "- " .. tostring(point))
		end
		table.insert(sections, table.concat(lines, "\n"))
	end

	if item.questions and #item.questions > 0 then
		local lines = { "## " .. _("Questions to think about") }
		for i, question in ipairs(item.questions) do
			table.insert(lines, tostring(i) .. ". " .. tostring(question))
		end
		table.insert(sections, table.concat(lines, "\n"))
	end

	if #sections == 0 then
		return _("No prereading content available for this chapter.")
	end

	return table.concat(sections, "\n\n")
end

--- Build the popup body as plain text, with markdown markers stripped
-- Fallback for older TextViewers without markdown rendering.
-- @param item table Prereading item with summary, keypoints, questions
-- @return string Multi-section plain text body
local function buildPrereadingBody(item)
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
		return _("No prereading content available for this chapter.")
	end

	return table.concat(sections, "\n\n")
end

--- Show the prereading popup for a matched chapter item
-- Renders the body as markdown (bold, headings, lists) when this KOReader's
-- TextViewer supports it, falling back to plain text with markers stripped.
-- @param item table Prereading item to display
function UI.showPrereadingPopup(item)
	if supportsMarkdown() then
		UIManager:show(TextViewer:new({
			title = buildPrereadingTitle(item),
			text = buildPrereadingMarkdown(item),
			text_format = "md",
		}))
	else
		UIManager:show(TextViewer:new({
			title = buildPrereadingTitle(item),
			text = buildPrereadingBody(item),
		}))
	end
end

--- Show a message when no prereading is cached and we are offline
function UI.showPrereadingNoCache()
	UI.showMessage(_("No prereading cached yet. Sync this book while online."), 4)
end

--- Show a message when the book is unknown to the server
function UI.showPrereadingBookUnknown()
	UI.showMessage(_("Book not found on Crossbill. Sync this book first."), 4)
end

--- Show a message when the book is known but has no prereading generated
function UI.showPrereadingEmptyBook()
	UI.showMessage(_("No prereading generated for this book yet. Generate it in the Crossbill web app."), 4)
end

--- Show a message when the current chapter could not be matched
function UI.showPrereadingChapterNotMatched()
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
-- Primary actions (sync, chapter summary) are top-level; everything else
-- lives under a Settings submenu.
-- @param handlers table Callback handlers for menu actions
--   - on_sync: function() Called when sync is triggered
--   - on_show_prereading: function() Called when the chapter summary is requested
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
				text = _("Chapter summary"),
				callback = handlers.on_show_prereading,
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
