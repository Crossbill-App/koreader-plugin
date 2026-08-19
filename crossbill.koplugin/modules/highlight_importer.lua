--[[
Highlight Importer Module for Crossbill Sync

Replaces the open book's KOReader highlights with the server's copy. The server
is the master: every highlight is rebuilt from the pulled items, page bookmarks
are left untouched, and the book's sidecar file is backed up before anything is
changed.

Only reflowable (rolling) documents are supported: the pulled positions are
xpointers, which mean nothing to a fixed-layout document.
]]

local DocSettings = require("docsettings")
local Event = require("ui/event")
local UIManager = require("ui/uimanager")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")

local HighlightImporter = {}
HighlightImporter.__index = HighlightImporter

local BACKUP_MARKER = ".crossbill-"
local BACKUPS_KEPT = 3

-- Drawers KOReader knows how to paint (highlight_style in readerhighlight.lua).
-- An unknown drawer would still count as a highlight but draw nothing, so
-- anything else falls back to the reader's own default.
local VALID_DRAWERS = {
	lighten = true,
	underscore = true,
	strikeout = true,
	invert = true,
}
local FALLBACK_DRAWER = "lighten"

--- Create a new HighlightImporter instance
-- @return HighlightImporter instance
function HighlightImporter:new()
	return setmetatable({}, HighlightImporter)
end

--- Read a value that is only useful as a string
-- Nullable JSON fields decode to a sentinel rather than nil, so anything that
-- is not a string counts as absent.
-- @param value any The raw value
-- @return string|nil The value if it is a string
local function asString(value)
	if type(value) ~= "string" then
		return nil
	end
	return value
end

--- Read a value that is only useful as a non-empty string
-- @param value any The raw value
-- @return string|nil The value if it is a non-empty string
local function asNonEmptyString(value)
	local text = asString(value)
	if text == "" then
		return nil
	end
	return text
end

--- Copy a file byte for byte
-- @param source string Path to read from
-- @param target string Path to write to
-- @return boolean Success status
-- @return string|nil Error message
local function copyFile(source, target)
	local input, input_err = io.open(source, "rb")
	if not input then
		return false, input_err or ("Cannot read " .. source)
	end
	local data = input:read("*a")
	input:close()
	if not data then
		return false, "Cannot read " .. source
	end

	local output, output_err = io.open(target, "wb")
	if not output then
		return false, output_err or ("Cannot write " .. target)
	end
	local written = output:write(data)
	output:close()
	if not written then
		return false, "Cannot write " .. target
	end

	return true, nil
end

--- Delete all but the newest backups of one sidecar file
-- @param sidecar_file string Path to the sidecar file the backups belong to
local function pruneBackups(sidecar_file)
	local dir, name = sidecar_file:match("^(.*)/([^/]+)$")
	if not dir or lfs.attributes(dir, "mode") ~= "directory" then
		return
	end

	local prefix = name .. BACKUP_MARKER
	local backups = {}
	for entry in lfs.dir(dir) do
		if entry:sub(1, #prefix) == prefix and entry:sub(-4) == ".bak" then
			table.insert(backups, entry)
		end
	end

	-- The timestamps are fixed-width and zero-padded, so the names sort oldest first.
	table.sort(backups)
	for i = 1, #backups - BACKUPS_KEPT do
		os.remove(dir .. "/" .. backups[i])
	end
end

--- Back up the book's sidecar file alongside itself
-- @param doc_path string Path to the open document
-- @return string|nil Path to the backup, nil when the book has no sidecar file yet
-- @return string|nil Error message
local function backupSidecar(doc_path)
	local sidecar_file = DocSettings:findSidecarFile(doc_path)
	if not sidecar_file then
		logger.dbg("Crossbill Importer: No sidecar file to back up")
		return nil, nil
	end

	local backup_path = sidecar_file .. BACKUP_MARKER .. os.date("%Y%m%d-%H%M%S") .. ".bak"
	local ok, err = copyFile(sidecar_file, backup_path)
	if not ok then
		return nil, err
	end

	logger.info("Crossbill Importer: Backed up sidecar to", backup_path)
	pruneBackups(sidecar_file)
	return backup_path, nil
end

--- Check that an xpointer resolves somewhere in the open document
-- @param document table The KOReader document
-- @param xpoint string The xpointer to test
-- @return boolean True when the xpointer points into this book
local function isInDocument(document, xpoint)
	local ok, in_document = pcall(function()
		return document:isXPointerInDocument(xpoint)
	end)
	return ok and in_document == true
end

--- Resolve the chapter title for a pulled highlight
-- The server's chapter name wins; without one, the device's own table of
-- contents provides the title the same way ReaderHighlight:saveHighlight does.
-- @param ui table The KOReader UI context
-- @param source table One item from the server's highlight list
-- @param start_xpoint string The highlight's start xpointer
-- @return string|nil The chapter title
local function chapterTitle(ui, source, start_xpoint)
	local name = asNonEmptyString(source.chapter_name)
	if name or not ui.toc then
		return name
	end
	return asNonEmptyString(ui.toc:getTocTitleByPage(start_xpoint))
end

--- Build a KOReader annotation from a pulled highlight
-- Mirrors the item ReaderHighlight:saveHighlight builds for a rolling document;
-- pageno and pageref are filled in by ReaderAnnotation:addItem.
-- @param ui table The KOReader UI context
-- @param source table One item from the server's highlight list
-- @param start_xpoint string The highlight's start xpointer
-- @param end_xpoint string The highlight's end xpointer
-- @param defaults table Fallback drawer and color
-- @return table The annotation item
local function buildItem(ui, source, start_xpoint, end_xpoint, defaults)
	local drawer = asString(source.device_style)
	local note = asNonEmptyString(source.note)
	return {
		page = start_xpoint,
		pos0 = start_xpoint,
		pos1 = end_xpoint,
		text = asString(source.text) or "",
		datetime = asNonEmptyString(source.datetime),
		datetime_updated = asNonEmptyString(source.datetime_updated),
		drawer = (drawer and VALID_DRAWERS[drawer]) and drawer or defaults.drawer,
		color = asNonEmptyString(source.device_color) or defaults.color,
		note = note,
		chapter = chapterTitle(ui, source, start_xpoint),
		crossbill_note_seen = note or "",
	}
end

--- Turn the server's items into annotations, counting what had to be skipped
-- @param ui table The KOReader UI context
-- @param items table Array of highlight items from the server
-- @param defaults table Fallback drawer and color
-- @param result table Result table whose skip counters are updated
-- @return table Array of annotation items, in the server's order
local function buildItems(ui, items, defaults, result)
	local built = {}

	for _, source in ipairs(items) do
		local start_xpoint = asNonEmptyString(source.start_xpoint)
		local end_xpoint = asNonEmptyString(source.end_xpoint)
		if source.placeable ~= true or not start_xpoint or not end_xpoint then
			result.skipped_unplaceable = result.skipped_unplaceable + 1
		elseif not isInDocument(ui.document, start_xpoint) or not isInDocument(ui.document, end_xpoint) then
			result.skipped_invalid = result.skipped_invalid + 1
		else
			table.insert(built, buildItem(ui, source, start_xpoint, end_xpoint, defaults))
		end
	end

	return built
end

--- Key an annotation by the position pair that identifies it
-- @param item table An annotation item
-- @return string The key
local function positionKey(item)
	return tostring(item.pos0) .. "\0" .. tostring(item.pos1)
end

--- Describe everything a replacement could change about one highlight
-- @param item table An annotation item
-- @return string The fields joined into one comparable string
local function fingerprint(item)
	return table.concat({
		item.text or "",
		item.note or "",
		item.drawer or "",
		tostring(item.color or ""),
		item.datetime_updated or "",
	}, "\0")
end

--- Check whether the reader already holds exactly the highlights we would insert
-- Bookmarks (annotations without a drawer) are left out: the replacement never
-- touches them. crossbill_note_seen is left out too, being the plugin's own
-- bookkeeping rather than something the server sends.
-- @param annotations table The reader's live annotation array
-- @param built table Array of annotation items built from the server's copy
-- @return boolean True when replacing would change nothing
local function sameHighlightSet(annotations, built)
	local device = {}
	local device_count = 0
	for _, item in ipairs(annotations) do
		if item.drawer then
			device[positionKey(item)] = fingerprint(item)
			device_count = device_count + 1
		end
	end

	if device_count ~= #built then
		return false
	end

	for _, item in ipairs(built) do
		if device[positionKey(item)] ~= fingerprint(item) then
			return false
		end
	end

	return true
end

--- Count the page bookmarks a replacement would keep
-- @param annotations table The reader's live annotation array
-- @return number Number of annotations without a drawer
local function countBookmarks(annotations)
	local kept = 0
	for _, item in ipairs(annotations) do
		if not item.drawer then
			kept = kept + 1
		end
	end
	return kept
end

--- Remove every highlight from the reader, keeping page bookmarks
-- Page bookmarks are exactly the annotations without a drawer (see
-- ReaderAnnotation:buildAnnotation). Removal goes through ReaderBookmark so
-- KOReader's own caches and counters stay in step, and walks backwards so the
-- remaining indexes stay valid.
-- @param ui table The KOReader UI context
-- @return number Number of page bookmarks kept
local function removeHighlights(ui)
	local annotations = ui.annotation.annotations
	local kept = 0

	for i = #annotations, 1, -1 do
		if annotations[i].drawer then
			ui.bookmark:removeItemByIndex(i)
		else
			kept = kept + 1
		end
	end

	return kept
end

--- Insert the built annotations, announcing each one like a new highlight
-- @param ui table The KOReader UI context
-- @param built table Array of annotation items
local function addItems(ui, built)
	for _, item in ipairs(built) do
		local index = ui.annotation:addItem(item)
		local payload = { item, index_modified = index }
		if item.note then
			payload.nb_notes_added = 1
		else
			payload.nb_highlights_added = 1
		end
		ui:handleEvent(Event:new("AnnotationsModified", payload))
	end
end

--- Restore a previously captured annotation array in place
-- @param annotations table The reader's live annotation array
-- @param previous table The captured copy
local function restoreAnnotations(annotations, previous)
	for i = #annotations, 1, -1 do
		table.remove(annotations, i)
	end
	for i, item in ipairs(previous) do
		annotations[i] = item
	end
end

--- Replace the open book's highlights with the server's copy
-- Returns early when the book already holds exactly the server's highlights, so
-- a sync that changed nothing neither rewrites the sidecar nor backs it up.
-- Otherwise backs up the sidecar file first, keeps page bookmarks, and flushes
-- the new set to disk before returning.
-- @param ui table The KOReader UI context
-- @param items table Array of highlight items from the server
-- @return table|nil Result with inserted, skipped_unplaceable, skipped_invalid,
--   kept_bookmarks, backup_path and unchanged, or nil on failure
-- @return string|nil Error message
function HighlightImporter:replaceHighlights(ui, items)
	if not ui.document or not ui.annotation or not ui.annotation.annotations then
		return nil, "No book is open"
	end
	if not ui.rolling then
		return nil, "Only reflowable books (EPUB) are supported"
	end

	local result = {
		inserted = 0,
		skipped_unplaceable = 0,
		skipped_invalid = 0,
		kept_bookmarks = 0,
	}

	local highlight_settings = (ui.view and ui.view.highlight) or {}
	local defaults = {
		drawer = highlight_settings.saved_drawer or FALLBACK_DRAWER,
		color = highlight_settings.saved_color,
	}
	local built = buildItems(ui, items, defaults, result)

	if sameHighlightSet(ui.annotation.annotations, built) then
		result.unchanged = true
		result.kept_bookmarks = countBookmarks(ui.annotation.annotations)
		logger.dbg("Crossbill Importer: Highlights already match the server's copy")
		return result, nil
	end

	-- The server has highlights for this book but none fits this copy of it:
	-- most likely a different edition, or positions the server could not keep.
	-- Wiping the device's highlights on that basis would be data loss, not sync.
	if #built == 0 and #items > 0 and countBookmarks(ui.annotation.annotations) < #ui.annotation.annotations then
		return nil, "None of the server's highlights fit this book; nothing changed"
	end

	ui:handleEvent(Event:new("FlushSettings"))

	local backup_path, backup_err = backupSidecar(ui.document.file)
	if backup_err then
		logger.err("Crossbill Importer: Could not back up the sidecar file:", backup_err)
		return nil, backup_err
	end
	result.backup_path = backup_path

	local previous = {}
	for i, item in ipairs(ui.annotation.annotations) do
		previous[i] = item
	end

	local ok, err = pcall(function()
		result.kept_bookmarks = removeHighlights(ui)
		addItems(ui, built)
		result.inserted = #built
	end)

	if not ok then
		logger.err("Crossbill Importer: Failed to replace highlights:", err)
		pcall(restoreAnnotations, ui.annotation.annotations, previous)
		-- The removals that did go through shifted the view's cached highlight
		-- boxes, so drop the cache wholesale rather than leave it half shifted.
		if ui.view and ui.view.resetHighlightBoxesCache then
			pcall(function()
				ui.view:resetHighlightBoxesCache()
			end)
		end
		UIManager:setDirty(ui.dialog, "ui")
		return nil, tostring(err)
	end

	if ui.view and ui.view.footer then
		ui.view.footer:maybeUpdateFooter()
	end
	ui:handleEvent(Event:new("FlushSettings"))
	UIManager:setDirty(ui.dialog, "ui")

	logger.info("Crossbill Importer: Replaced highlights with", result.inserted, "from the server")
	return result, nil
end

return HighlightImporter
