local DocumentSupport = require("modules/document_support")

--- Build a minimal fake of KOReader's UI context around a document path
-- @param path any The document's file path
-- @return table A UI context with a document
local function uiFor(path)
	return { document = { file = path } }
end

describe("DocumentSupport", function()
	describe("isSupportedDocument", function()
		it("accepts an EPUB", function()
			assert.is_true(DocumentSupport.isSupportedDocument(uiFor("/mnt/books/dune.epub")))
		end)

		it("accepts an EPUB whose extension is upper case", function()
			assert.is_true(DocumentSupport.isSupportedDocument(uiFor("/mnt/books/Dune.EPUB")))
		end)

		it("accepts a Kobo EPUB", function()
			assert.is_true(DocumentSupport.isSupportedDocument(uiFor("/mnt/books/dune.kepub.epub")))
		end)

		it("rejects a PDF", function()
			assert.is_false(DocumentSupport.isSupportedDocument(uiFor("/mnt/books/paper.pdf")))
		end)

		it("rejects other reflowable formats the server has no EPUB for", function()
			assert.is_false(DocumentSupport.isSupportedDocument(uiFor("/mnt/books/dune.fb2")))
			assert.is_false(DocumentSupport.isSupportedDocument(uiFor("/mnt/books/dune.mobi")))
			assert.is_false(DocumentSupport.isSupportedDocument(uiFor("/mnt/books/dune.txt")))
		end)

		it("rejects a name that merely contains .epub", function()
			assert.is_false(DocumentSupport.isSupportedDocument(uiFor("/mnt/books/dune.epub.zip")))
		end)

		it("rejects a document with no path", function()
			assert.is_false(DocumentSupport.isSupportedDocument(uiFor(nil)))
		end)

		it("rejects a UI with no document open", function()
			assert.is_false(DocumentSupport.isSupportedDocument({}))
		end)

		it("rejects a missing UI context", function()
			assert.is_false(DocumentSupport.isSupportedDocument(nil))
		end)
	end)
end)
