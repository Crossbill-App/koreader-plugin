--[[
Book Metadata Module for Crossbill Sync

Extracts book metadata from KOReader documents including:
- Title, author, description
- ISBN from identifiers
- Language, page count
- Keywords/tags
]]

local DocSettings = require("docsettings")
local Log = require("modules/log")
local log = Log.forModule("BookMetadata")
local BookIdentity = require("modules/book_identity")

local BookMetadata = {}
BookMetadata.__index = BookMetadata

--- Create a new BookMetadata instance
-- @param ui table The KOReader UI context (self.ui from plugin)
-- @return BookMetadata instance
function BookMetadata:new(ui)
	local instance = setmetatable({}, BookMetadata)
	instance.ui = ui
	return instance
end

--- Extract filename from a file path
-- Public because the EPUB upload names the file it sends with it, and a second
-- copy of the pattern is a second place to get it wrong. A path with no
-- separator in it is already a bare filename, so it is handed back whole
-- rather than replaced with a placeholder.
-- @param path string Full file path
-- @return string Filename only
function BookMetadata.getFilename(path)
	return path:match("^.+/(.+)$") or path
end

--- Extract ISBN from identifiers string
-- The format can vary: "ISBN:9780735211292\nAMAZON:..." or "ISBN:9780735211292 AMAZON:..."
-- @param identifiers string The identifiers string
-- @return string|nil ISBN if found
local function extractISBN(identifiers)
	if not identifiers then
		return nil
	end

	-- Match ISBN: followed by digits/hyphens/X until we hit a non-ISBN character
	local isbn = identifiers:match("ISBN:([%d%-xX]+)")
	if isbn then
		log.dbg("Extracted ISBN:", isbn)
	else
		log.dbg("No ISBN found in identifiers:", identifiers)
	end
	return isbn
end

--- Parse keywords string into array
-- Keywords are separated by newlines
-- @param keywords_str string The keywords string
-- @return table|nil Array of keywords
local function parseKeywords(keywords_str)
	if not keywords_str then
		return nil
	end

	local keywords = {}
	for keyword in keywords_str:gmatch("[^\n]+") do
		local trimmed = keyword:match("^%s*(.-)%s*$")
		if trimmed and trimmed ~= "" then
			table.insert(keywords, trimmed)
		end
	end

	if #keywords > 0 then
		log.dbg("Extracted", #keywords, "keywords")
		return keywords
	end
	return nil
end

--- Get document settings for metadata
-- @param doc_path string Path to the document
-- @return table Combined metadata from doc_props and doc_settings
function BookMetadata:getDocMetadata(doc_path)
	local doc_settings = DocSettings:open(doc_path)
	local book_props = self.ui.doc_props

	-- Merge doc_settings metadata with live doc_props
	local metadata_props = doc_settings:readSetting("doc_props") or book_props

	return {
		book_props = book_props,
		metadata_props = metadata_props,
		doc_settings = doc_settings,
	}
end

--- Extract complete book metadata
-- @return table Book data ready for API upload
function BookMetadata:extractBookData()
	local doc_path = self.ui.document.file
	local meta = self:getDocMetadata(doc_path)

	local book_props = meta.book_props
	local metadata_props = meta.metadata_props
	local doc_settings = meta.doc_settings

	local isbn = extractISBN(metadata_props.identifiers)

	local language = metadata_props.language or nil
	if language then
		log.dbg("Extracted language:", language)
	end

	local page_count = doc_settings:readSetting("doc_pages") or nil
	if page_count then
		log.dbg("Extracted page count:", page_count)
	end

	local keywords = parseKeywords(metadata_props.keywords)

	local title = book_props.display_title or book_props.title or BookMetadata.getFilename(doc_path)
	local author = book_props.authors or nil
	local client_book_id = BookIdentity.clientBookId(title, author)
	log.dbg("Syncing book:", title, "client_book_id:", client_book_id)

	return {
		title = title,
		author = author,
		client_book_id = client_book_id,
		isbn = isbn,
		description = metadata_props.description or nil,
		language = language,
		page_count = page_count,
		keywords = keywords,
	}
end

--- Get document path
-- @return string Document file path
function BookMetadata:getDocPath()
	return self.ui.document.file
end

return BookMetadata
