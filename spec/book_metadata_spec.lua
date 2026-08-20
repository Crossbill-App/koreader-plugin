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

		it("prefers the persisted doc_props over the live ones for metadata", function()
			DocSettings.setFixture(DOC_PATH, {
				doc_props = { language = "fi", description = "Aavikko" },
			})

			local data = extractorFor({ title = "Dune", language = "en" }):extractBookData()

			assert.are.equal("fi", data.language)
			assert.are.equal("Aavikko", data.description)
		end)

		it("falls back to the live doc_props when nothing is persisted", function()
			local data = extractorFor({ title = "Dune", language = "en" }):extractBookData()

			assert.are.equal("en", data.language)
		end)
	end)

	describe("ISBN extraction", function()
		--- Extract the ISBN the plugin would report for an identifiers string
		-- @param identifiers string|nil The raw identifiers value
		-- @return string|nil The extracted ISBN
		local function isbnFrom(identifiers)
			DocSettings.setFixture(DOC_PATH, { doc_props = { identifiers = identifiers } })
			return extractorFor({ title = "Dune" }):extractBookData().isbn
		end

		it("reads a bare ISBN identifier", function()
			assert.are.equal("9780735211292", isbnFrom("ISBN:9780735211292"))
		end)

		it("reads an ISBN from a newline-separated list", function()
			assert.are.equal("9780735211292", isbnFrom("ISBN:9780735211292\nAMAZON:B01N5AX61W"))
		end)

		it("reads an ISBN from a space-separated list", function()
			assert.are.equal("9780735211292", isbnFrom("AMAZON:B01N5AX61W ISBN:9780735211292"))
		end)

		it("keeps hyphens and a trailing X check digit", function()
			assert.are.equal("0-306-40615-X", isbnFrom("ISBN:0-306-40615-X"))
		end)

		it("returns nil when no ISBN is present", function()
			assert.is_nil(isbnFrom("AMAZON:B01N5AX61W"))
		end)

		it("returns nil when there are no identifiers", function()
			assert.is_nil(isbnFrom(nil))
		end)
	end)

	describe("keyword parsing", function()
		--- Extract the keywords the plugin would report for a keywords string
		-- @param keywords string|nil The raw newline-separated keywords
		-- @return table|nil The parsed keywords
		local function keywordsFrom(keywords)
			DocSettings.setFixture(DOC_PATH, { doc_props = { keywords = keywords } })
			return extractorFor({ title = "Dune" }):extractBookData().keywords
		end

		it("splits keywords on newlines", function()
			assert.are.same({ "sci-fi", "classics" }, keywordsFrom("sci-fi\nclassics"))
		end)

		it("trims surrounding whitespace from each keyword", function()
			assert.are.same({ "sci-fi", "classics" }, keywordsFrom("  sci-fi  \n\tclassics\t"))
		end)

		it("drops blank and whitespace-only entries", function()
			assert.are.same({ "sci-fi" }, keywordsFrom("sci-fi\n\n   \n"))
		end)

		it("returns nil rather than an empty table when nothing survives", function()
			assert.is_nil(keywordsFrom("   \n\t"))
		end)

		it("returns nil when there are no keywords", function()
			assert.is_nil(keywordsFrom(nil))
		end)
	end)

	describe("document access", function()
		it("reports the document path", function()
			assert.are.equal(DOC_PATH, extractorFor({}):getDocPath())
		end)

		it("knows when a document is loaded", function()
			assert.is_true(extractorFor({}):hasDocument())
		end)

		it("knows when no document is loaded", function()
			assert.is_false(BookMetadata:new({ doc_props = {} }):hasDocument())
		end)
	end)
end)
