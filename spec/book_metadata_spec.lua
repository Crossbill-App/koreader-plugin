local BookMetadata = require("modules/book_metadata")
local DocSettings = require("docsettings")

local DOC_PATH = "/mnt/books/dune.epub"

--- Build a BookMetadata over a minimal fake of KOReader's UI context
-- @param doc_props table|nil The live document properties
-- @return BookMetadata instance
local function extractorFor(doc_props)
	return BookMetadata:new({
		document = { file = DOC_PATH },
		doc_props = doc_props or {},
	})
end

describe("BookMetadata", function()
	before_each(function()
		DocSettings.reset()
	end)

	describe("extractBookData", function()
		it("prefers the display title over the raw title", function()
			local data = extractorFor({ title = "dune", display_title = "Dune" }):extractBookData()

			assert.are.equal("Dune", data.title)
		end)

		it("falls back to the raw title when there is no display title", function()
			local data = extractorFor({ title = "Dune" }):extractBookData()

			assert.are.equal("Dune", data.title)
		end)

		it("falls back to the filename when the document has no title at all", function()
			local data = extractorFor({}):extractBookData()

			assert.are.equal("dune.epub", data.title)
		end)

		it("uses the whole path as the title when it has no directory part", function()
			local metadata = BookMetadata:new({ document = { file = "dune.epub" }, doc_props = {} })

			assert.are.equal("dune.epub", metadata:extractBookData().title)
		end)

		it("derives client_book_id from title and author", function()
			local data = extractorFor({ title = "Dune", authors = "Frank Herbert" }):extractBookData()

			-- The digest is stubbed (see spec/support/koreader/ffi/sha2.lua); what
			-- matters is the exact string hashed, since the server deduplicates on it.
			assert.are.equal("md5:Dune|Frank Herbert", data.client_book_id)
		end)

		it("still derives a client_book_id when the author is unknown", function()
			local data = extractorFor({ title = "Dune" }):extractBookData()

			assert.are.equal("md5:Dune|", data.client_book_id)
			assert.is_nil(data.author)
		end)

		it("gives two books with the same title but different authors distinct ids", function()
			local one = extractorFor({ title = "Selected Poems", authors = "Rilke" }):extractBookData()
			local two = extractorFor({ title = "Selected Poems", authors = "Neruda" }):extractBookData()

			assert.are_not.equal(one.client_book_id, two.client_book_id)
		end)

		it("reads page count from the document settings", function()
			DocSettings.setFixture(DOC_PATH, { doc_pages = 412 })

			assert.are.equal(412, extractorFor({ title = "Dune" }):extractBookData().page_count)
		end)

		it("leaves page count unset when the book has never been paginated", function()
			assert.is_nil(extractorFor({ title = "Dune" }):extractBookData().page_count)
		end)
	end)

	describe("document access", function()
		it("reports the document path", function()
			assert.are.equal(DOC_PATH, extractorFor({}):getDocPath())
		end)
	end)
end)
