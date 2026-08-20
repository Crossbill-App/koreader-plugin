local HighlightExtractor = require("modules/highlight_extractor")
local DocSettings = require("docsettings")

local DOC_PATH = "/mnt/books/dune.epub"

--- Build a HighlightExtractor over a minimal fake of KOReader's UI context
-- @param ui table|nil Overrides for the UI context (annotation, toc, document)
-- @return HighlightExtractor instance
local function extractorFor(ui)
	ui = ui or {}
	return HighlightExtractor:new({
		document = ui.document or { file = DOC_PATH },
		annotation = ui.annotation,
		toc = ui.toc,
	})
end

--- Wrap an array of annotations the way ReaderAnnotation holds them
-- @param annotations table Array of raw annotations
-- @return table A stand-in for `ui.annotation`
local function annotationModule(annotations)
	return { annotations = annotations }
end

describe("HighlightExtractor", function()
	before_each(function()
		DocSettings.reset()
	end)

	describe("getHighlightsFromMemory", function()
		it("returns nil when ReaderAnnotation is not loaded", function()
			assert.is_nil(extractorFor():getHighlightsFromMemory())
		end)

		it("returns nil when there are no annotations", function()
			assert.is_nil(extractorFor({ annotation = annotationModule({}) }):getHighlightsFromMemory())
		end)

		it("keeps annotations that have a drawer", function()
			local extractor = extractorFor({
				annotation = annotationModule({
					{ drawer = "lighten", text = "the spice must flow" },
				}),
			})

			local highlights = extractor:getHighlightsFromMemory()

			assert.are.equal(1, #highlights)
			assert.are.equal("the spice must flow", highlights[1].text)
		end)

		it("drops page bookmarks, which carry no drawer", function()
			local extractor = extractorFor({
				annotation = annotationModule({
					{ drawer = "lighten", text = "a highlight" },
					{ text = "in Chapter 2" },
				}),
			})

			local highlights = extractor:getHighlightsFromMemory()

			assert.are.equal(1, #highlights)
			assert.are.equal("a highlight", highlights[1].text)
		end)

		it("returns an empty list when every annotation is a bookmark", function()
			local extractor = extractorFor({
				annotation = annotationModule({ { text = "in Chapter 2" } }),
			})

			assert.are.same({}, extractor:getHighlightsFromMemory())
		end)

		it("maps every field of an annotation onto the highlight", function()
			local extractor = extractorFor({
				annotation = annotationModule({
					{
						drawer = "underscore",
						text = "the spice must flow",
						note = "remember this",
						datetime = "2024-05-01 12:00:00",
						pageno = 42,
						pos0 = "/body/DocFragment[3]/p[1]/text()[0]",
						pos1 = "/body/DocFragment[3]/p[1]/text()[19]",
						chapter = "Book One",
						color = "yellow",
					},
				}),
			})

			assert.are.same({
				text = "the spice must flow",
				note = "remember this",
				datetime = "2024-05-01 12:00:00",
				page = 42,
				start_xpoint = "/body/DocFragment[3]/p[1]/text()[0]",
				end_xpoint = "/body/DocFragment[3]/p[1]/text()[19]",
				chapter = "Book One",
				color = "yellow",
				drawer = "underscore",
			}, extractor:getHighlightsFromMemory()[1])
		end)

		it("drops fixed-layout positions, which are coordinate tables", function()
			local extractor = extractorFor({
				annotation = annotationModule({
					{
						drawer = "lighten",
						text = "the spice must flow",
						pos0 = { x = 10, y = 20, page = 3 },
						pos1 = { x = 90, y = 20, page = 3 },
					},
				}),
			})

			local highlight = extractor:getHighlightsFromMemory()[1]

			assert.is_nil(highlight.start_xpoint)
			assert.is_nil(highlight.end_xpoint)
		end)

		it("carries datetime_updated through when the annotation has one", function()
			local extractor = extractorFor({
				annotation = annotationModule({
					{ drawer = "lighten", datetime_updated = "2024-05-02 09:30:00" },
				}),
			})

			assert.are.equal("2024-05-02 09:30:00", extractor:getHighlightsFromMemory()[1].datetime_updated)
		end)

		it("falls back to `page` when the annotation has no `pageno`", function()
			local extractor = extractorFor({
				annotation = annotationModule({ { drawer = "lighten", page = 7 } }),
			})

			assert.are.equal(7, extractor:getHighlightsFromMemory()[1].page)
		end)

		it("defaults missing text and datetime to empty strings", function()
			local extractor = extractorFor({
				annotation = annotationModule({ { drawer = "lighten" } }),
			})

			local highlight = extractor:getHighlightsFromMemory()[1]

			assert.are.equal("", highlight.text)
			assert.are.equal("", highlight.datetime)
		end)
	end)

	describe("getHighlightsFromDisk", function()
		it("returns nil when the sidecar holds nothing", function()
			assert.is_nil(extractorFor():getHighlightsFromDisk(DOC_PATH))
		end)

		it("reads the modern annotations format", function()
			DocSettings.setFixture(DOC_PATH, {
				annotations = {
					{ drawer = "lighten", text = "a highlight", pageno = 3 },
					{ text = "a bookmark" },
				},
			})

			local highlights = extractorFor():getHighlightsFromDisk(DOC_PATH)

			assert.are.equal(1, #highlights)
			assert.are.equal("a highlight", highlights[1].text)
			assert.are.equal(3, highlights[1].page)
		end)

		it("prefers the modern format even when legacy highlights are also present", function()
			DocSettings.setFixture(DOC_PATH, {
				annotations = { { drawer = "lighten", text = "modern" } },
				highlight = { [1] = { { text = "legacy" } } },
			})

			local highlights = extractorFor():getHighlightsFromDisk(DOC_PATH)

			assert.are.equal(1, #highlights)
			assert.are.equal("modern", highlights[1].text)
		end)

		it("flattens the legacy per-page highlight format", function()
			DocSettings.setFixture(DOC_PATH, {
				highlight = {
					[1] = { { text = "first", datetime = "2024-01-01 10:00:00", page = 1 } },
					[2] = { { text = "second", datetime = "2024-01-02 10:00:00", page = 2 } },
				},
			})

			local highlights = extractorFor():getHighlightsFromDisk(DOC_PATH)

			assert.are.equal(2, #highlights)
		end)

		it("pulls legacy notes from the matching bookmark", function()
			DocSettings.setFixture(DOC_PATH, {
				highlight = {
					[1] = { { text = "first", datetime = "2024-01-01 10:00:00", page = 1 } },
				},
				bookmarks = {
					{ datetime = "2024-01-01 10:00:00", text = "my note" },
				},
			})

			assert.are.equal("my note", extractorFor():getHighlightsFromDisk(DOC_PATH)[1].note)
		end)

		it("leaves the note unset when no bookmark shares the timestamp", function()
			DocSettings.setFixture(DOC_PATH, {
				highlight = {
					[1] = { { text = "first", datetime = "2024-01-01 10:00:00", page = 1 } },
				},
				bookmarks = { { datetime = "2024-06-06 06:00:00", text = "other note" } },
			})

			assert.is_nil(extractorFor():getHighlightsFromDisk(DOC_PATH)[1].note)
		end)

		it("keeps legacy xpointer positions and drops coordinate tables", function()
			DocSettings.setFixture(DOC_PATH, {
				highlight = {
					[1] = {
						{
							text = "reflowable",
							datetime = "2024-01-01 10:00:00",
							pos0 = "/body/DocFragment[3]/p[1]/text()[0]",
							pos1 = "/body/DocFragment[3]/p[1]/text()[9]",
						},
					},
					[2] = {
						{
							text = "fixed layout",
							datetime = "2024-01-02 10:00:00",
							pos0 = { x = 10, y = 20, page = 2 },
							pos1 = { x = 90, y = 20, page = 2 },
						},
					},
				},
			})

			-- The legacy format is a map of pages, so the flattened order is not
			-- guaranteed; look each highlight up by its text.
			local by_text = {}
			for _, highlight in ipairs(extractorFor():getHighlightsFromDisk(DOC_PATH)) do
				by_text[highlight.text] = highlight
			end

			assert.are.equal("/body/DocFragment[3]/p[1]/text()[0]", by_text["reflowable"].start_xpoint)
			assert.are.equal("/body/DocFragment[3]/p[1]/text()[9]", by_text["reflowable"].end_xpoint)
			assert.is_nil(by_text["fixed layout"].start_xpoint)
			assert.is_nil(by_text["fixed layout"].end_xpoint)
		end)
	end)

	describe("getHighlights", function()
		it("prefers memory over disk, so unflushed highlights are not missed", function()
			DocSettings.setFixture(DOC_PATH, {
				annotations = { { drawer = "lighten", text = "stale disk copy" } },
			})
			local extractor = extractorFor({
				annotation = annotationModule({ { drawer = "lighten", text = "fresh in memory" } }),
			})

			assert.are.equal("fresh in memory", extractor:getHighlights(DOC_PATH)[1].text)
		end)

		it("falls back to disk when nothing is in memory", function()
			DocSettings.setFixture(DOC_PATH, {
				annotations = { { drawer = "lighten", text = "from disk" } },
			})

			assert.are.equal("from disk", extractorFor():getHighlights(DOC_PATH)[1].text)
		end)
	end)

	describe("addChapterNumbers", function()
		-- A flat ToC in the same order the server sees it: chapter_number is an
		-- index into this array, which is how the server associates highlights
		-- with chapters.
		local TOC = {
			{ title = "Book One", page = 1 },
			{ title = "Chapter 1", page = 1 },
			{ title = "Chapter 2", page = 20 },
			{ title = "Book Two", page = 50 },
			{ title = "Chapter 3", page = 50 },
		}

		--- Resolve chapter numbers for one highlight against a ToC
		-- @param highlight table The highlight to augment
		-- @param ui table|nil The UI context; defaults to TOC being loaded. Pass
		--   an explicit table to model a missing or different ToC.
		-- @return number|nil The resolved chapter number
		local function chapterNumberFor(highlight, ui)
			local highlights = extractorFor(ui or { toc = { toc = TOC } }):addChapterNumbers({ highlight })
			return highlights[1].chapter_number
		end

		it("leaves chapter numbers unset when there is no ToC", function()
			assert.is_nil(chapterNumberFor({ page = 25 }, {}))
		end)

		it("leaves chapter numbers unset when the ToC is empty", function()
			assert.is_nil(chapterNumberFor({ page = 25 }, { toc = { toc = {} } }))
		end)

		it("returns the same array it was given", function()
			local highlights = { { page = 25 } }

			assert.are.equal(highlights, extractorFor({ toc = { toc = TOC } }):addChapterNumbers(highlights))
		end)

		it("picks the last ToC entry that starts at or before the page", function()
			assert.are.equal(3, chapterNumberFor({ page = 25 }))
		end)

		it("picks the last entry when several share a start page", function()
			assert.are.equal(2, chapterNumberFor({ page = 10 }))
		end)

		it("accepts a page given as a numeric string", function()
			assert.are.equal(3, chapterNumberFor({ page = "25" }))
		end)

		it("prefers a shallower ToC entry when its title matches the highlight", function()
			-- Page 55 sits in "Chapter 3" (index 5), but KOReader recorded the
			-- highlight's chapter at the shallower "Book Two" depth.
			assert.are.equal(4, chapterNumberFor({ page = 55, chapter = "Book Two" }))
		end)

		it("uses the containing entry when its own title matches", function()
			assert.are.equal(5, chapterNumberFor({ page = 55, chapter = "Chapter 3" }))
		end)

		it("matches titles ignoring case and whitespace runs", function()
			assert.are.equal(4, chapterNumberFor({ page = 55, chapter = "  book\n\tTWO  " }))
		end)

		it("trusts position when no earlier entry matches the title", function()
			assert.are.equal(5, chapterNumberFor({ page = 55, chapter = "Appendix" }))
		end)

		it("falls back to the first title match when the page precedes the whole ToC", function()
			assert.are.equal(3, chapterNumberFor({ page = 0, chapter = "Chapter 2" }))
		end)

		it("leaves the number unset when the page precedes the ToC and no title matches", function()
			assert.is_nil(chapterNumberFor({ page = 0, chapter = "Appendix" }))
		end)

		it("resolves a non-numeric page through the document's xpointer lookup", function()
			local document = {
				file = DOC_PATH,
				getPageFromXPointer = function(_, xpointer)
					assert.are.equal("/body/DocFragment[3]", xpointer)
					return 25
				end,
			}

			local ui = { document = document, toc = { toc = TOC } }

			assert.are.equal(3, chapterNumberFor({ page = "/body/DocFragment[3]" }, ui))
		end)

		it("falls back to the title when the xpointer lookup throws", function()
			local document = {
				file = DOC_PATH,
				getPageFromXPointer = function()
					error("document not rendered")
				end,
			}
			local highlight = { page = "/body/DocFragment[3]", chapter = "Chapter 2" }
			local ui = { document = document, toc = { toc = TOC } }

			assert.are.equal(3, chapterNumberFor(highlight, ui))
		end)

		it("leaves the number unset when neither page nor chapter can be resolved", function()
			assert.is_nil(chapterNumberFor({ page = nil, chapter = nil }))
		end)

		it("ignores a non-string chapter such as a JSON null sentinel", function()
			assert.is_nil(chapterNumberFor({ page = nil, chapter = {} }))
		end)
	end)
end)
