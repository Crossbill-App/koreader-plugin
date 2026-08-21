--[[
Highlight Extractor Module for Crossbill Sync

Extracts highlights from KOReader documents, from ReaderAnnotation's memory or
from the sidecar on disk.
Also handles chapter number mapping from table of contents.
]]

local DocSettings = require("docsettings")
local logger = require("logger")
local TitleMatch = require("modules/title_match")

-- Chapter titles are matched the same way everywhere; see modules/title_match.
local normalizeTitle = TitleMatch.normalize

local HighlightExtractor = {}
HighlightExtractor.__index = HighlightExtractor

--- Create a new HighlightExtractor instance
-- @param ui table The KOReader UI context (self.ui from plugin)
-- @return HighlightExtractor instance
function HighlightExtractor:new(ui)
	local instance = setmetatable({}, HighlightExtractor)
	instance.ui = ui
	return instance
end

--- Tell highlights apart from page bookmarks
-- KOReader keeps both in the same annotations array; page bookmarks have no
-- drawer and carry a generated "in <chapter>" text, which would otherwise be
-- uploaded as a highlight.
-- @param annotation table One item from ReaderAnnotation's annotations
-- @return boolean True for highlights (with or without a note)
local function isHighlight(annotation)
	return annotation.drawer ~= nil
end

-- Positions are xpointer strings for reflowable documents, but tables of
-- coordinates for fixed-layout ones, which the server has no use for.
local function asXpoint(position)
	if type(position) == "string" then
		return position
	end
	return nil
end

--- Convert a raw annotation to our standard highlight format
-- @param annotation table The raw annotation object
-- @return table Formatted highlight object
local function formatHighlight(annotation)
	return {
		text = annotation.text or "",
		note = annotation.note or nil,
		datetime = annotation.datetime or "",
		datetime_updated = annotation.datetime_updated,
		page = annotation.pageno or annotation.page,
		start_xpoint = asXpoint(annotation.pos0),
		end_xpoint = asXpoint(annotation.pos1),
		chapter = annotation.chapter or nil,
		color = annotation.color or nil,
		drawer = annotation.drawer or nil,
	}
end

--- Get highlights directly from ReaderAnnotation's memory
-- This is preferred as it captures annotations not yet flushed to disk. An
-- existing but empty annotations array is authoritative and yields an empty
-- list: the stale sidecar must not resurrect highlights deleted in memory.
-- @return table|nil Array of highlights, or nil when ReaderAnnotation is absent
function HighlightExtractor:getHighlightsFromMemory()
	if not self.ui.annotation then
		logger.dbg("Crossbill Extractor: ReaderAnnotation module not available")
		return nil
	end

	local annotations = self.ui.annotation.annotations
	if not annotations then
		logger.dbg("Crossbill Extractor: No annotations in memory")
		return nil
	end

	logger.dbg("Crossbill Extractor: Found", #annotations, "annotations in memory")
	local results = {}

	for _, annotation in ipairs(annotations) do
		if isHighlight(annotation) then
			table.insert(results, formatHighlight(annotation))
		end
	end

	logger.dbg("Crossbill Extractor: Converted", #results, "annotations to highlights")
	return results
end

--- Get highlights from document settings file (disk)
-- Only the annotations format is read. KOReader migrates a pre-ReaderAnnotation
-- sidecar the moment it opens the book (2024.04), and this plugin needs that
-- same ReaderAnnotation API, so a sidecar still holding the legacy `highlight`
-- table cannot reach us.
-- @param doc_path string Path to the document
-- @return table|nil Array of highlights, or nil if none found
function HighlightExtractor:getHighlightsFromDisk(doc_path)
	local doc_settings = DocSettings:open(doc_path)
	local annotations = doc_settings:readSetting("annotations")
	if not annotations then
		logger.dbg("Crossbill Extractor: No highlights found in settings")
		return nil
	end

	local results = {}
	for _, annotation in ipairs(annotations) do
		if isHighlight(annotation) then
			table.insert(results, formatHighlight(annotation))
		end
	end

	logger.dbg("Crossbill Extractor: Found", #results, "highlights on disk")
	return results
end

--- Get all highlights, trying memory first then falling back to disk
-- @param doc_path string Path to the document
-- @return table|nil Array of highlights
function HighlightExtractor:getHighlights(doc_path)
	return self:getHighlightsFromMemory() or self:getHighlightsFromDisk(doc_path)
end

--- Resolve a highlight's numeric page, following xpointers when needed
-- Highlights carry `page` from annotation.pageno or annotation.page (see
-- formatHighlight). A numeric page is used directly; a non-numeric string is
-- treated as an xpointer and resolved via the document, defensively pcall-wrapped.
-- @param document table|nil The KOReader document
-- @param highlight table The formatted highlight
-- @return number|nil The numeric page, or nil if unresolvable
local function getNumericPage(document, highlight)
	local numeric = tonumber(highlight.page)
	if numeric then
		return numeric
	end

	if type(highlight.page) ~= "string" then
		return nil
	end

	local ok, page = pcall(function()
		if document and document.getPageFromXPointer then
			return document:getPageFromXPointer(highlight.page)
		end
		return nil
	end)

	if ok and page then
		return tonumber(page)
	end

	return nil
end

--- Find the flat ToC index containing a page: the last entry whose page <= page
-- Same convention as findCurrentTocEntry in digest_service.lua.
-- @param toc table The flat ToC array
-- @param page number The highlight's page
-- @return number|nil The 1-based index into toc, or nil if none
local function findContainingTocIndex(toc, page)
	local containing_index = nil
	for i, entry in ipairs(toc) do
		local entry_page = tonumber(entry.page)
		if entry_page and entry_page <= page then
			-- Keep advancing; the last matching entry contains the page
			containing_index = i
		end
	end
	return containing_index
end

--- Find the first flat ToC index whose title matches the given normalized title
-- First occurrence is deterministic (unlike the old last-wins title map).
-- @param toc table The flat ToC array
-- @param title_norm string|nil The normalized target title
-- @return number|nil The 1-based index, or nil if none matches
local function findFirstTitleIndex(toc, title_norm)
	if not title_norm then
		return nil
	end
	for i, entry in ipairs(toc) do
		if normalizeTitle(entry.title) == title_norm then
			return i
		end
	end
	return nil
end

--- Resolve the chapter number (flat ToC index) for a single highlight
-- Position-first, verified by title. The server associates highlights to
-- chapters solely via this number matching the server's flat TOC order.
-- @param toc table The flat ToC array
-- @param highlight table The formatted highlight
-- @param numeric_page number|nil The highlight's resolved numeric page
-- @return number|nil The chapter number, or nil if unresolvable
local function resolveChapterNumber(toc, highlight, numeric_page)
	local chapter_norm = normalizeTitle(highlight.chapter)

	if numeric_page then
		local containing_index = findContainingTocIndex(toc, numeric_page)
		if not containing_index then
			-- No entry precedes this page; fall back to title-only matching.
			return findFirstTitleIndex(toc, chapter_norm)
		end

		-- No chapter title on the highlight: trust the position.
		if not chapter_norm then
			return containing_index
		end

		-- The containing entry's title matches: use it directly.
		if normalizeTitle(toc[containing_index].title) == chapter_norm then
			return containing_index
		end

		-- Titles differ: KOReader's annotation chapter can come from a shallower
		-- ToC depth than the containing leaf entry. Walk backwards to the nearest
		-- entry whose title equals the highlight's chapter.
		for i = containing_index - 1, 1, -1 do
			if normalizeTitle(toc[i].title) == chapter_norm then
				return i
			end
		end

		-- No title match found; position is more trustworthy than nothing.
		return containing_index
	end

	-- No numeric page could be resolved: fall back to first-occurrence title match.
	return findFirstTitleIndex(toc, chapter_norm)
end

--- Add chapter numbers to highlights based on reading position, verified by title
-- Resolves each highlight's flat ToC index position-first and mutates the array
-- in place, setting highlight.chapter_number. Leaves it unset when unresolvable
-- (the server tolerates missing numbers with a warning).
-- @param highlights table Array of highlights to augment
-- @return table The same highlights array with chapter_number added
function HighlightExtractor:addChapterNumbers(highlights)
	local toc = self.ui.toc and self.ui.toc.toc
	if not toc or #toc == 0 then
		logger.dbg("Crossbill Extractor: No TOC available; leaving chapter numbers unset")
		return highlights
	end

	local document = self.ui.document

	for _, highlight in ipairs(highlights) do
		local numeric_page = getNumericPage(document, highlight)
		local chapter_number = resolveChapterNumber(toc, highlight, numeric_page)
		if chapter_number then
			highlight.chapter_number = chapter_number
		end
	end

	return highlights
end

return HighlightExtractor
