--[[
Book Metadata Module for Crossbill Sync

Extracts what the sync sends about a KOReader document: title, author, the
client book id derived from them, and the page count.
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
-- Public because the book upload names the file it sends with it, and a second
-- copy of the pattern is a second place to get it wrong. A path with no
-- separator in it is already a bare filename, so it is handed back whole
-- rather than replaced with a placeholder.
-- @param path string Full file path
-- @return string Filename only
function BookMetadata.getFilename(path)
	return path:match("^.+/(.+)$") or path
end

--- Extract the book data the sync sends
-- @return table title, author, client_book_id and page_count
function BookMetadata:extractBookData()
	local doc_path = self.ui.document.file
	local book_props = self.ui.doc_props

	local page_count = DocSettings:open(doc_path):readSetting("doc_pages")
	if page_count then
		log.dbg("Extracted page count:", page_count)
	end

	local title = book_props.display_title or book_props.title or BookMetadata.getFilename(doc_path)
	local author = book_props.authors or nil
	local client_book_id = BookIdentity.clientBookId(title, author)
	log.dbg("Syncing book:", title, "client_book_id:", client_book_id)

	return {
		title = title,
		author = author,
		client_book_id = client_book_id,
		page_count = page_count,
	}
end

--- Get document path
-- @return string Document file path
function BookMetadata:getDocPath()
	return self.ui.document.file
end

return BookMetadata
