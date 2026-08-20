local HighlightImporter = require("modules/highlight_importer")

-- An xpointer the fake document resolves, unless a test says otherwise.
local XPOINT_A = "/body/DocFragment[3]/p[1]/text()[0]"
local XPOINT_B = "/body/DocFragment[3]/p[1]/text()[19]"
local XPOINT_C = "/body/DocFragment[7]/p[2]/text()[0]"
local XPOINT_D = "/body/DocFragment[7]/p[2]/text()[8]"

-- Nullable JSON fields decode to a sentinel rather than to nil; the importer
-- has to treat anything that is not a string as absent.
local JSON_NULL = setmetatable({}, {
	__tostring = function()
		return "null"
	end,
})

--- Build a fake of the reader context the importer writes through
-- The annotation and bookmark modules mutate one shared array, exactly as
-- KOReader's do, so a spec can read `reader.annotations` back afterwards.
-- @param opts table|nil rolling, annotations, resolves, toc_title, highlight defaults
-- @return table A stand-in for `self.ui`, with `events` recording what it handled
local function readerFor(opts)
	opts = opts or {}
	local annotations = opts.annotations or {}
	local resolves = opts.resolves

	local reader = {
		rolling = opts.rolling ~= false or nil,
		events = {},
		annotations = annotations,
		dialog = "dialog",
	}

	reader.document = opts.document
		or {
			isXPointerInDocument = function(_, xpoint)
				if resolves == nil then
					return true
				end
				return resolves[xpoint] == true
			end,
		}

	reader.annotation = {
		annotations = annotations,
		addItem = function(_, item)
			table.insert(annotations, item)
			return #annotations
		end,
	}

	reader.bookmark = {
		removeItemByIndex = function(_, index)
			table.remove(annotations, index)
		end,
	}

	if opts.toc_title ~= nil then
		reader.toc = {
			getTocTitleByPage = function(_, _)
				return opts.toc_title
			end,
		}
	end

	reader.view = {
		highlight = opts.highlight or {},
		footer = { maybeUpdateFooter = function() end },
		resetHighlightBoxesCache = function() end,
	}

	--- Record an event the importer dispatched
	-- @param event table The event built by `Event:new`
	function reader:handleEvent(event)
		table.insert(self.events, event)
	end

	--- Collect the events of one name
	-- @param name string The event name
	-- @return table Array of matching events
	function reader:eventsNamed(name)
		local found = {}
		for _, event in ipairs(self.events) do
			if event.name == name then
				table.insert(found, event)
			end
		end
		return found
	end

	return reader
end

--- Build a server highlight item, placeable and resolvable by default
-- @param fields table|nil Overrides for the item
-- @return table One item as the server's highlight list holds it
local function serverItem(fields)
	local item = {
		placeable = true,
		start_xpoint = XPOINT_A,
		end_xpoint = XPOINT_B,
		text = "the spice must flow",
	}
	for key, value in pairs(fields or {}) do
		item[key] = value
	end
	return item
end

--- Build the annotation a device holds for a highlight
-- @param fields table|nil Overrides for the annotation
-- @return table An annotation item
local function deviceHighlight(fields)
	local item = {
		drawer = "lighten",
		pos0 = XPOINT_A,
		pos1 = XPOINT_B,
		text = "the spice must flow",
	}
	for key, value in pairs(fields or {}) do
		item[key] = value
	end
	return item
end

--- Collect the annotations that carry a drawer
-- @param reader table The reader fake
-- @return table Array of highlight annotations
local function highlightsOf(reader)
	local found = {}
	for _, item in ipairs(reader.annotations) do
		if item.drawer then
			table.insert(found, item)
		end
	end
	return found
end

describe("HighlightImporter", function()
	local importer

	before_each(function()
		importer = HighlightImporter:new()
	end)

	describe("guards", function()
		it("refuses when no document is open", function()
			local reader = readerFor()
			reader.document = nil

			local result, err = importer:replaceHighlights(reader, {})

			assert.is_nil(result)
			assert.are.equal("No book is open", err)
		end)

		it("refuses when the annotation module is not loaded", function()
			local reader = readerFor()
			reader.annotation = nil

			local result, err = importer:replaceHighlights(reader, {})

			assert.is_nil(result)
			assert.are.equal("No book is open", err)
		end)

		it("refuses a fixed-layout book, whose positions are not xpointers", function()
			local reader = readerFor({ rolling = false })

			local result, err = importer:replaceHighlights(reader, { serverItem() })

			assert.is_nil(result)
			assert.are.equal("Only reflowable books (EPUB) are supported", err)
		end)

		it("changes nothing when none of the server's highlights fit this book", function()
			-- A different edition, most likely: wiping the device on that basis
			-- would be data loss rather than sync.
			local existing = deviceHighlight()
			local reader = readerFor({ annotations = { existing }, resolves = {} })

			local result, err = importer:replaceHighlights(reader, { serverItem({ start_xpoint = XPOINT_C }) })

			assert.is_nil(result)
			assert.are.equal("None of the server's highlights fit this book; nothing changed", err)
			assert.are.same({ existing }, reader.annotations)
		end)

		it("still empties a book whose highlights the server no longer has", function()
			-- An empty server list is a real answer, not a failed placement:
			-- the user deleted the highlights in the web app.
			local reader = readerFor({ annotations = { deviceHighlight() } })

			local result = importer:replaceHighlights(reader, {})

			assert.are.equal(0, result.inserted)
			assert.are.same({}, highlightsOf(reader))
		end)
	end)

	describe("skipping", function()
		it("skips an item the server could not place", function()
			local reader = readerFor()

			local result = importer:replaceHighlights(reader, { serverItem({ placeable = false }) })

			assert.are.equal(1, result.skipped_unplaceable)
			assert.are.equal(0, result.inserted)
		end)

		it("skips an item missing a start or end position", function()
			local reader = readerFor()

			-- Spelled out rather than built by overriding, because an override
			-- to nil simply leaves the default in place.
			local result = importer:replaceHighlights(reader, {
				{ placeable = true, end_xpoint = XPOINT_B },
				{ placeable = true, start_xpoint = XPOINT_A },
				{ placeable = true, start_xpoint = XPOINT_A, end_xpoint = "" },
				{ placeable = true, start_xpoint = JSON_NULL, end_xpoint = XPOINT_B },
			})

			assert.are.equal(4, result.skipped_unplaceable)
			assert.are.equal(0, result.inserted)
		end)

		it("skips an item whose position does not resolve in this book", function()
			local reader = readerFor({ resolves = { [XPOINT_A] = true, [XPOINT_B] = true } })

			local result = importer:replaceHighlights(reader, {
				serverItem(),
				serverItem({ start_xpoint = XPOINT_C, end_xpoint = XPOINT_D }),
			})

			assert.are.equal(1, result.skipped_invalid)
			assert.are.equal(1, result.inserted)
		end)

		it("skips an item whose end position alone does not resolve", function()
			local reader = readerFor({ resolves = { [XPOINT_A] = true } })

			local result = importer:replaceHighlights(reader, { serverItem() })

			assert.are.equal(1, result.skipped_invalid)
		end)

		it("skips an item whose lookup throws rather than failing the pull", function()
			local reader = readerFor({
				document = {
					isXPointerInDocument = function()
						error("document closed")
					end,
				},
			})

			local result = importer:replaceHighlights(reader, { serverItem() })

			assert.are.equal(1, result.skipped_invalid)
			assert.are.equal(0, result.inserted)
		end)

		it("counts the two kinds of skip apart", function()
			local reader = readerFor({ resolves = { [XPOINT_A] = true, [XPOINT_B] = true } })

			local result = importer:replaceHighlights(reader, {
				serverItem(),
				serverItem({ placeable = false }),
				serverItem({ start_xpoint = XPOINT_C, end_xpoint = XPOINT_D }),
			})

			assert.are.equal(1, result.inserted)
			assert.are.equal(1, result.skipped_unplaceable)
			assert.are.equal(1, result.skipped_invalid)
		end)
	end)

	describe("the annotations it builds", function()
		it("mirrors the item KOReader builds for a rolling document", function()
			local reader = readerFor()

			importer:replaceHighlights(reader, {
				serverItem({
					text = "the spice must flow",
					note = "remember this",
					datetime = "2024-05-01 12:00:00",
					datetime_updated = "2024-05-02 09:30:00",
					device_style = "underscore",
					device_color = "cyan",
					chapter_name = "Book One",
				}),
			})

			assert.are.same({
				page = XPOINT_A,
				pos0 = XPOINT_A,
				pos1 = XPOINT_B,
				text = "the spice must flow",
				note = "remember this",
				datetime = "2024-05-01 12:00:00",
				datetime_updated = "2024-05-02 09:30:00",
				drawer = "underscore",
				color = "cyan",
				chapter = "Book One",
				crossbill_note_seen = "remember this",
			}, highlightsOf(reader)[1])
		end)

		it("keeps the server's order", function()
			local reader = readerFor()

			importer:replaceHighlights(reader, {
				serverItem({ text = "first" }),
				serverItem({ start_xpoint = XPOINT_C, end_xpoint = XPOINT_D, text = "second" }),
			})

			local highlights = highlightsOf(reader)
			assert.are.equal("first", highlights[1].text)
			assert.are.equal("second", highlights[2].text)
		end)

		it("falls back to the reader's drawer for an unknown style", function()
			local reader = readerFor({ highlight = { saved_drawer = "invert" } })

			importer:replaceHighlights(reader, { serverItem({ device_style = "sparkles" }) })

			assert.are.equal("invert", highlightsOf(reader)[1].drawer)
		end)

		it("falls back to lighten when the reader has no saved drawer", function()
			local reader = readerFor()

			importer:replaceHighlights(reader, { serverItem({ device_style = JSON_NULL }) })

			assert.are.equal("lighten", highlightsOf(reader)[1].drawer)
		end)

		it("keeps every drawer KOReader knows how to paint", function()
			for _, drawer in ipairs({ "lighten", "underscore", "strikeout", "invert" }) do
				local reader = readerFor()

				importer:replaceHighlights(reader, { serverItem({ device_style = drawer }) })

				assert.are.equal(drawer, highlightsOf(reader)[1].drawer)
			end
		end)

		it("falls back to the reader's colour when the server sends none", function()
			local reader = readerFor({ highlight = { saved_color = "gray" } })

			importer:replaceHighlights(reader, { serverItem({ device_color = JSON_NULL }) })

			assert.are.equal("gray", highlightsOf(reader)[1].color)
		end)

		it("takes the chapter title from the device's own ToC when the server sends none", function()
			local reader = readerFor({ toc_title = "Chapter Seven" })

			importer:replaceHighlights(reader, { serverItem({ chapter_name = "" }) })

			assert.are.equal("Chapter Seven", highlightsOf(reader)[1].chapter)
		end)

		it("prefers the server's chapter name over the device's ToC", function()
			local reader = readerFor({ toc_title = "Chapter Seven" })

			importer:replaceHighlights(reader, { serverItem({ chapter_name = "Book One" }) })

			assert.are.equal("Book One", highlightsOf(reader)[1].chapter)
		end)

		it("leaves the chapter unset when neither side names one", function()
			local reader = readerFor()

			importer:replaceHighlights(reader, { serverItem({ chapter_name = JSON_NULL }) })

			assert.is_nil(highlightsOf(reader)[1].chapter)
		end)

		it("treats a null note as no note at all", function()
			local reader = readerFor()

			importer:replaceHighlights(reader, { serverItem({ note = JSON_NULL }) })

			local highlight = highlightsOf(reader)[1]
			assert.is_nil(highlight.note)
			assert.are.equal("", highlight.crossbill_note_seen)
		end)

		it("seeds crossbill_note_seen so the pulled note is not restamped as an edit", function()
			local reader = readerFor()

			importer:replaceHighlights(reader, { serverItem({ note = "remember this" }) })

			assert.are.equal("remember this", highlightsOf(reader)[1].crossbill_note_seen)
		end)

		it("falls back to empty text rather than nil", function()
			local reader = readerFor()

			importer:replaceHighlights(reader, { serverItem({ text = JSON_NULL }) })

			assert.are.equal("", highlightsOf(reader)[1].text)
		end)
	end)

	describe("when the book already matches the server", function()
		it("reports it as unchanged and inserts nothing", function()
			local reader = readerFor({ annotations = { deviceHighlight() } })

			local result = importer:replaceHighlights(reader, { serverItem() })

			assert.is_true(result.unchanged)
			assert.are.equal(0, result.inserted)
		end)

		it("leaves the annotations untouched, so the sidecar is not rewritten", function()
			local existing = deviceHighlight()
			local reader = readerFor({ annotations = { existing } })

			importer:replaceHighlights(reader, { serverItem() })

			assert.are.equal(existing, reader.annotations[1])
			assert.are.same({}, reader.events)
		end)

		it("counts the page bookmarks it is leaving alone", function()
			local reader = readerFor({
				annotations = { deviceHighlight(), { text = "in Chapter 2" }, { text = "in Chapter 5" } },
			})

			local result = importer:replaceHighlights(reader, { serverItem() })

			assert.is_true(result.unchanged)
			assert.are.equal(2, result.kept_bookmarks)
		end)

		it("ignores the plugin's own bookkeeping when comparing", function()
			-- crossbill_note_seen is never sent by the server, so a difference
			-- there must not force a rewrite.
			local reader = readerFor({
				annotations = { deviceHighlight({ note = "remember this", crossbill_note_seen = "stale" }) },
			})

			local result = importer:replaceHighlights(reader, { serverItem({ note = "remember this" }) })

			assert.is_true(result.unchanged)
		end)

		it("replaces when a note differs", function()
			local reader = readerFor({ annotations = { deviceHighlight({ note = "old note" }) } })

			local result = importer:replaceHighlights(reader, { serverItem({ note = "new note" }) })

			assert.is_nil(result.unchanged)
			assert.are.equal(1, result.inserted)
			assert.are.equal("new note", highlightsOf(reader)[1].note)
		end)

		it("replaces when the colour differs", function()
			local reader = readerFor({ annotations = { deviceHighlight({ color = "yellow" }) } })

			local result = importer:replaceHighlights(reader, { serverItem({ device_color = "cyan" }) })

			assert.are.equal(1, result.inserted)
		end)

		it("replaces when the edit timestamp differs", function()
			local reader = readerFor({
				annotations = { deviceHighlight({ datetime_updated = "2024-05-01 12:00:00" }) },
			})

			local result = importer:replaceHighlights(reader, {
				serverItem({ datetime_updated = "2024-05-02 09:30:00" }),
			})

			assert.are.equal(1, result.inserted)
		end)

		it("replaces when the server holds one highlight more", function()
			local reader = readerFor({ annotations = { deviceHighlight() } })

			local result = importer:replaceHighlights(reader, {
				serverItem(),
				serverItem({ start_xpoint = XPOINT_C, end_xpoint = XPOINT_D }),
			})

			assert.are.equal(2, result.inserted)
		end)

		it("replaces when a highlight sits at a different position", function()
			local reader = readerFor({ annotations = { deviceHighlight({ pos1 = XPOINT_D }) } })

			local result = importer:replaceHighlights(reader, { serverItem() })

			assert.are.equal(1, result.inserted)
			assert.are.equal(XPOINT_B, highlightsOf(reader)[1].pos1)
		end)

		it("does not count page bookmarks towards the comparison", function()
			local reader = readerFor({ annotations = { { text = "in Chapter 2" }, deviceHighlight() } })

			local result = importer:replaceHighlights(reader, { serverItem() })

			assert.is_true(result.unchanged)
		end)
	end)

	describe("replacing", function()
		it("removes the highlights the server no longer has", function()
			local reader = readerFor({
				annotations = { deviceHighlight({ text = "deleted in the web app" }) },
			})

			importer:replaceHighlights(reader, { serverItem({ text = "kept" }) })

			local highlights = highlightsOf(reader)
			assert.are.equal(1, #highlights)
			assert.are.equal("kept", highlights[1].text)
		end)

		it("keeps page bookmarks and counts them", function()
			local reader = readerFor({
				annotations = { { text = "in Chapter 2" }, deviceHighlight({ text = "old" }) },
			})

			local result = importer:replaceHighlights(reader, { serverItem({ text = "new" }) })

			assert.are.equal(1, result.kept_bookmarks)
			assert.are.equal("in Chapter 2", reader.annotations[1].text)
		end)

		it("announces each insert the way a new highlight is announced", function()
			local reader = readerFor()

			importer:replaceHighlights(reader, { serverItem(), serverItem({ start_xpoint = XPOINT_C }) })

			local events = reader:eventsNamed("AnnotationsModified")
			assert.are.equal(2, #events)
			assert.are.equal(1, events[1].args[1].nb_highlights_added)
			assert.is_not_nil(events[1].args[1].index_modified)
		end)

		it("announces a highlight carrying a note as a note", function()
			local reader = readerFor()

			importer:replaceHighlights(reader, { serverItem({ note = "remember this" }) })

			local payload = reader:eventsNamed("AnnotationsModified")[1].args[1]
			assert.are.equal(1, payload.nb_notes_added)
			assert.is_nil(payload.nb_highlights_added)
		end)

		it("flushes the new set to disk", function()
			local reader = readerFor()

			importer:replaceHighlights(reader, { serverItem() })

			assert.are.equal(1, #reader:eventsNamed("FlushSettings"))
		end)

		it("puts the highlights back when the replacement throws", function()
			local existing = deviceHighlight()
			local reader = readerFor({ annotations = { existing } })
			reader.annotation.addItem = function()
				error("annotation module blew up")
			end

			local result, err = importer:replaceHighlights(reader, { serverItem({ text = "new" }) })

			assert.is_nil(result)
			assert.is_truthy(err:find("annotation module blew up", 1, true))
			assert.are.same({ existing }, reader.annotations)
		end)

		it("does not flush a failed replacement to disk", function()
			local reader = readerFor({ annotations = { deviceHighlight() } })
			reader.annotation.addItem = function()
				error("annotation module blew up")
			end

			importer:replaceHighlights(reader, { serverItem({ text = "new" }) })

			assert.are.equal(0, #reader:eventsNamed("FlushSettings"))
		end)
	end)
end)
