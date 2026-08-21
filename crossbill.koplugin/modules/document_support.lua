--[[
Document Support Module for Crossbill Sync

Decides whether the open document is a book Crossbill can work with.

Crossbill's whole model is built on the EPUB: the server stores the EPUB, and
every highlight is anchored to an XPointer into that file. A PDF, a DjVu or a
CBZ has no such anchors, and a fb2 or mobi produces anchors the server has no
matching EPUB to resolve. Syncing any of those uploads highlights nobody can
place and records reading sessions against a book the server cannot show, so
the plugin stays out of the way entirely on anything but an EPUB.
]]

local DocumentSupport = {}

--- Check whether a file path names an EPUB
-- @param path string|nil The document's file path
-- @return boolean True when the path ends in .epub, in any casing
function DocumentSupport.isEpubPath(path)
	if type(path) ~= "string" then
		return false
	end
	return path:lower():match("%.epub$") ~= nil
end

--- Check whether the open document is one Crossbill supports
-- @param ui table|nil The KOReader UI context (self.ui from the plugin)
-- @return boolean True when an EPUB is open
function DocumentSupport.isSupportedDocument(ui)
	if not ui or not ui.document then
		return false
	end
	return DocumentSupport.isEpubPath(ui.document.file)
end

return DocumentSupport
