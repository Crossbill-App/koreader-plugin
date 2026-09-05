--[[
Digest Format Module for Crossbill Sync

Turns a digest item into the strings the popup shows: a title, a rich HTML
body, and a plain-text body for the viewer the popup falls back to.

Pure string work, kept apart from the widgets that display it on purpose, so
it can be exercised without a UIManager standing in for a screen.

Public API:
  DigestFormat.title(item)     -> string
  DigestFormat.html(item)      -> string
  DigestFormat.plainText(item) -> string
]]

local _ = require("gettext")

local DigestFormat = {}

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

--- Build the display title for a digest item
-- @param item table Digest item with chapter_name and parent_chapter_name
-- @return string Title, prefixed with the parent chapter name when present
function DigestFormat.title(item)
	local chapter_name = item.chapter_name or _("Chapter")
	if item.parent_chapter_name and item.parent_chapter_name ~= "" then
		return item.parent_chapter_name .. " › " .. chapter_name
	end
	return chapter_name
end

--- Build the popup body as HTML, with inline markdown rendered as tags
-- Summary paragraphs (separated by blank lines) become <p> blocks; key points
-- become a <ul>, questions an <ol>. All content flows through
-- inlineMarkdownToHtml so bold/italics/code render properly.
-- @param item table Digest item with summary, keypoints, questions
-- @return string HTML body
function DigestFormat.html(item)
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
function DigestFormat.plainText(item)
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

return DigestFormat
