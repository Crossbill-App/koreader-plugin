local DocSettings = require("docsettings")
local FakeSessionStore = require("fake_session_store")
local GlobalSettingsFake = require("global_settings_fake")
local SessionTracker = require("modules/sessiontracker")

local FILE = "/books/dune.epub"
local TITLE = "Dune"
local AUTHOR = "Frank Herbert"

-- Where the clock starts. Any fixed value will do; sessions are only ever
-- compared against it and against each other.
local START_TIME = 1700000000

-- The tracker's own thresholds, restated here so a test can sit deliberately on
-- either side of one. They are not exported: a test that had to read them out
-- of the module would pass whatever they became.
local ACTIVITY_GAP_SECONDS = 1800
local CAPTURE_INTERVAL_SECONDS = 60

-- The shortest session the settings below will keep.
local MIN_DURATION = 60

--- Build a clock a test can move by hand
-- The tracker reads elapsed time to decide when a sitting ended and when to
-- capture a position again, so a test that could not move the clock could only
-- assert the throttle never fires.
-- @param start number Unix time the clock starts at
-- @return table A clock with `now` and `advance`
local function fakeClock(start)
	local clock = { time = start }

	--- Read the clock
	-- @return number The current time
	function clock.now()
		return clock.time
	end

	--- Move the clock forward
	-- @param seconds number How far to move it
	function clock.advance(seconds)
		clock.time = clock.time + seconds
	end

	return clock
end

--- Build a reflowable document whose position the test can move
-- Reflowable, so the tracker records XPointers; see `pagedDocument` for the
-- EPUB that KOReader opened with MuPDF instead.
-- @param xpointer string Where the reader is
-- @return table The document stand-in
local function documentAt(xpointer)
	return {
		file = FILE,
		xpointer = xpointer,
		getXPointer = function(self)
			return self.xpointer
		end,
		getProps = function()
			return { title = TITLE, authors = AUTHOR }
		end,
		getPageCount = function()
			return 412
		end,
	}
end

--- Build an EPUB that KOReader opened as a paged document
-- What "Open with... MuPDF" produces: the file still ends in .epub, so the
-- plugin is active, but the document has pages and no XPointer method at all.
-- @return table The document stand-in
local function pagedDocument()
	local document = documentAt(nil)
	document.getXPointer = nil
	document.info = { has_pages = true }
	return document
end

--- Build the reader UI around a document
-- @param document table The document stand-in
-- @param page number The page on screen
-- @return table The UI stand-in
local function uiFor(document, page)
	return {
		document = document,
		doc_props = { title = TITLE, authors = AUTHOR },
		view = { state = { page = page } },
	}
end

-- How long the book is that `bookOpenAt` builds.
local BOOK_PAGES = 10

--- Where a page of the `bookOpenAt` book starts, under a given layout
-- A relayout moves every page's start, so the layout is part of the answer.
-- @param page number The page
-- @param layout string|nil The layout's name, "default" when nil
-- @return string The XPointer of the page's first text
local function pageStart(page, layout)
	return string.format("/body/DocFragment[2]/p[%d]@%s", page, layout or "default")
end

--- Build a reflowable book the test turns the pages of
-- What KOReader hands the plugin in page mode: the page on screen starts at
-- `getXPointer()`, and any page's start is `getPageXPointer(page)`. Past the
-- last page crengine answers an empty XPointer, and this does the same.
-- @param page number The page on screen
-- @return table The document stand-in, with `page`, `layout` and
--   `visible_page_numbers` for the test to change
local function bookOpenAt(page)
	local document = documentAt(nil)
	document.page = page
	document.layout = nil
	document.visible_page_numbers = 1
	document.getXPointer = function(self)
		return pageStart(self.page, self.layout)
	end
	document.getPageXPointer = function(self, n)
		if n < 1 or n > BOOK_PAGES then
			return ""
		end
		return pageStart(n, self.layout)
	end
	document.getPageCount = function()
		return BOOK_PAGES
	end
	document.getVisiblePageNumberCount = function(self)
		return self.visible_page_numbers
	end
	return document
end

--- Build the reader UI around a book read in page mode
-- @param document table The `bookOpenAt` document
-- @return table The UI stand-in, whose `view.view_mode` the test can change
local function pageModeUiFor(document)
	local ui = uiFor(document, document.page)
	ui.view.view_mode = "page"
	return ui
end

--- Turn the book to a page, the way KOReader's PageUpdate reaches the tracker
-- @param tracker table The tracker
-- @param document table The `bookOpenAt` document
-- @param ui table Its UI
-- @param page number The page turned to
local function turnTo(tracker, document, ui, page)
	document.page = page
	ui.view.state.page = page
	tracker:updatePosition(document, ui, page)
end

--- Build settings that keep sessions of at least MIN_DURATION
-- @param min_duration number|nil The minimum to report
-- @return table The settings stand-in
local function settingsKeeping(min_duration)
	return {
		getMinReadingSessionDuration = function()
			return min_duration or MIN_DURATION
		end,
	}
end

--- Build a tracker over a fake store and a movable clock
-- @param opts table|nil store, settings, clock and init
-- @return table The tracker
-- @return table The store behind it
-- @return table The clock it reads
local function trackerWith(opts)
	opts = opts or {}
	local store = opts.store or FakeSessionStore:new()
	local clock = opts.clock or fakeClock(START_TIME)
	local tracker = SessionTracker:new({
		settings = opts.settings or settingsKeeping(),
		store = store,
		now = clock.now,
	})
	if opts.init ~= false then
		tracker:init("/settings")
	end
	return tracker, store, clock
end

describe("SessionTracker", function()
	local global

	before_each(function()
		-- The device id a saved session carries is read through the settings
		-- global; the id itself is DeviceIdentity's business, not this module's.
		global = GlobalSettingsFake.install()
		DocSettings.reset()
	end)

	after_each(function()
		global.uninstall()
	end)

	describe("init", function()
		it("opens the store in the given data directory", function()
			local _, store = trackerWith()

			assert.are.equal("/settings", store.opened_with)
		end)

		it("reports a store that would not open", function()
			local store = FakeSessionStore:new()
			store.fails_at = "open"
			local tracker = trackerWith({ store = store, init = false })

			assert.is_false(tracker:init("/settings"))
		end)

		it("refuses without a store to open", function()
			local tracker = SessionTracker:new({ settings = settingsKeeping() })

			assert.is_false(tracker:init("/settings"))
		end)

		it("opens the store once, however often it is asked", function()
			local tracker, store = trackerWith()
			store.opened_with = nil

			assert.is_true(tracker:init("/elsewhere"))
			assert.is_nil(store.opened_with)
		end)
	end)

	describe("startSession", function()
		it("tracks a session from where the reader is", function()
			local tracker, store, clock = trackerWith()
			local document = documentAt("/body/DocFragment[3]")
			local ui = uiFor(document, 42)

			tracker:startSession(document, ui)
			assert.is_true(tracker:hasActiveSession())

			clock.advance(MIN_DURATION)
			tracker:endSession(document, ui, "document_close")

			local session = store.sessions[1]
			assert.are.equal(FILE, session.book_file)
			assert.are.equal("md5:" .. FILE, session.book_hash)
			assert.are.equal(TITLE, session.book_title)
			assert.are.equal(AUTHOR, session.book_author)
			assert.are.equal("xpointer", session.position_type)
			assert.are.equal("/body/DocFragment[3]", session.start_position)
			assert.are.equal(42, session.start_page)
			assert.are.equal(412, session.total_pages)
			assert.are.equal(START_TIME, session.start_time)
			assert.is_true(type(session.device_id) == "string" and session.device_id ~= "")
		end)

		it("records the page, not an XPointer, for an EPUB opened as a paged document", function()
			local tracker, store, clock = trackerWith()
			local document = pagedDocument()
			local ui = uiFor(document, 17)

			tracker:startSession(document, ui)
			clock.advance(MIN_DURATION)
			tracker:endSession(document, ui, "document_close")

			local session = store.sessions[1]
			assert.are.equal("page", session.position_type)
			assert.are.equal("17", session.start_position)
			assert.are.equal(17, session.start_page)
		end)

		it("records no page count for a document that cannot say how long it is", function()
			local tracker, store, clock = trackerWith()
			local document = documentAt("/body/DocFragment[1]")
			document.getPageCount = nil
			local ui = uiFor(document, 1)

			tracker:startSession(document, ui)
			clock.advance(MIN_DURATION)
			tracker:endSession(document, ui, "document_close")

			assert.are.equal(0, store.sessions[1].total_pages)
		end)

		it("falls back to the document's own properties when metadata extraction fails", function()
			local tracker, store, clock = trackerWith()
			local document = documentAt("/body/DocFragment[1]")
			-- No doc_props: BookMetadata reaches into it and raises, which is
			-- the failure the fallback exists for.
			local ui = { document = document, view = { state = { page = 1 } } }

			tracker:startSession(document, ui)
			clock.advance(MIN_DURATION)
			tracker:endSession(document, ui, "document_close")

			assert.are.equal(TITLE, store.sessions[1].book_title)
			assert.are.equal(AUTHOR, store.sessions[1].book_author)
		end)

		it("does not start without a document", function()
			local tracker = trackerWith()

			tracker:startSession(nil, nil)

			assert.is_false(tracker:hasActiveSession())
		end)

		it("does not start for a document with no file to identify it by", function()
			-- Every such document would otherwise share one hash, and their
			-- sessions would reach the server as a single book.
			local tracker, store, clock = trackerWith()
			local document = documentAt("/body/DocFragment[1]")
			document.file = nil

			tracker:startSession(document, uiFor(document, 1))
			assert.is_false(tracker:hasActiveSession())

			clock.advance(MIN_DURATION)
			assert.are.equal(0, #store.sessions)
		end)

		it("does not start when the store never opened", function()
			local store = FakeSessionStore:new()
			store.fails_at = "open"
			local tracker = trackerWith({ store = store })
			local document = documentAt("/body/DocFragment[1]")

			tracker:startSession(document, uiFor(document, 1))

			assert.is_false(tracker:hasActiveSession())
		end)

		it("ends the session already running before starting another", function()
			local tracker, store, clock = trackerWith()
			local document = documentAt("/body/DocFragment[1]")
			local ui = uiFor(document, 1)

			tracker:startSession(document, ui)
			clock.advance(MIN_DURATION)
			document.xpointer = "/body/DocFragment[2]"
			tracker:startSession(document, ui)

			assert.are.equal(1, #store.sessions)
			assert.are.equal("/body/DocFragment[2]", store.sessions[1].end_position)
			assert.is_true(tracker:hasActiveSession())
		end)
	end)

	describe("updatePosition", function()
		it("follows the page without capturing a position on every turn", function()
			local tracker, store, clock = trackerWith()
			local document = documentAt("/body/DocFragment[1]")
			local ui = uiFor(document, 1)

			tracker:startSession(document, ui)
			clock.advance(CAPTURE_INTERVAL_SECONDS - 1)
			document.xpointer = "/body/DocFragment[2]"
			tracker:updatePosition(document, ui, 7)

			-- Ended without a document, so nothing recaptures: what is saved is
			-- what the page turns tracked.
			clock.advance(MIN_DURATION)
			tracker:endSession(nil, nil, "app_exit")

			assert.are.equal("/body/DocFragment[1]", store.sessions[1].end_position)
			assert.are.equal(7, store.sessions[1].end_page)
		end)

		it("captures the position again once the interval has passed", function()
			local tracker, store, clock = trackerWith()
			local document = documentAt("/body/DocFragment[1]")
			local ui = uiFor(document, 1)

			tracker:startSession(document, ui)
			clock.advance(CAPTURE_INTERVAL_SECONDS)
			document.xpointer = "/body/DocFragment[2]"
			tracker:updatePosition(document, ui, 7)

			clock.advance(MIN_DURATION)
			tracker:endSession(nil, nil, "app_exit")

			assert.are.equal("/body/DocFragment[2]", store.sessions[1].end_position)
		end)

		it("captures the position when there is no page number to go on", function()
			local tracker, store, clock = trackerWith()
			local document = documentAt("/body/DocFragment[1]")
			local ui = uiFor(document, 1)

			tracker:startSession(document, ui)
			clock.advance(1)
			document.xpointer = "/body/DocFragment[2]"
			tracker:updatePosition(document, ui, nil)

			clock.advance(MIN_DURATION)
			tracker:endSession(nil, nil, "app_exit")

			assert.are.equal("/body/DocFragment[2]", store.sessions[1].end_position)
		end)

		it("splits the sitting at a long gap, ending the old one where it stopped", function()
			local tracker, store, clock = trackerWith()
			local document = documentAt("/body/DocFragment[1]")
			local ui = uiFor(document, 1)

			tracker:startSession(document, ui)
			clock.advance(CAPTURE_INTERVAL_SECONDS)
			document.xpointer = "/body/DocFragment[2]"
			tracker:updatePosition(document, ui, 7)
			local stopped_at = clock.now()

			-- The book is put down, and picked up again much later somewhere
			-- else entirely.
			clock.advance(ACTIVITY_GAP_SECONDS + 1)
			document.xpointer = "/body/DocFragment[9]"
			tracker:updatePosition(document, uiFor(document, 50), 50)

			assert.are.equal(1, #store.sessions)
			local ended = store.sessions[1]
			assert.are.equal(START_TIME, ended.start_time)
			assert.are.equal(stopped_at, ended.end_time)
			assert.are.equal(CAPTURE_INTERVAL_SECONDS, ended.duration_seconds)
			-- Where reading stopped, not where the reader turned up hours later.
			assert.are.equal("/body/DocFragment[2]", ended.end_position)
			assert.are.equal(7, ended.end_page)

			-- And a fresh sitting is running from where the book was reopened.
			assert.is_true(tracker:hasActiveSession())
			clock.advance(MIN_DURATION)
			tracker:endSession(nil, nil, "app_exit")

			local resumed = store.sessions[2]
			assert.are.equal(stopped_at + ACTIVITY_GAP_SECONDS + 1, resumed.start_time)
			assert.are.equal("/body/DocFragment[9]", resumed.start_position)
		end)

		it("does nothing without a session to update", function()
			local tracker, store = trackerWith()
			local document = documentAt("/body/DocFragment[1]")

			tracker:updatePosition(document, uiFor(document, 1), 3)

			assert.are.equal(0, #store.sessions)
		end)
	end)

	describe("endSession", function()
		it("saves where the reader had got to", function()
			local tracker, store, clock = trackerWith()
			local document = documentAt("/body/DocFragment[1]")
			local ui = uiFor(document, 1)

			tracker:startSession(document, ui)
			clock.advance(MIN_DURATION)
			document.xpointer = "/body/DocFragment[4]"
			ui.view.state.page = 88
			tracker:endSession(document, ui, "document_close")

			local session = store.sessions[1]
			assert.are.equal("/body/DocFragment[4]", session.end_position)
			assert.are.equal(88, session.end_page)
			assert.are.equal(START_TIME + MIN_DURATION, session.end_time)
			assert.are.equal(MIN_DURATION, session.duration_seconds)
			assert.is_false(tracker:hasActiveSession())
		end)

		it("ends at the last activity when reading stopped long ago", function()
			local tracker, store, clock = trackerWith()
			local document = documentAt("/body/DocFragment[1]")
			local ui = uiFor(document, 1)

			tracker:startSession(document, ui)
			clock.advance(CAPTURE_INTERVAL_SECONDS)
			document.xpointer = "/body/DocFragment[3]"
			tracker:updatePosition(document, ui, 12)
			local stopped_at = clock.now()

			-- The device suspended without telling us and came back much later,
			-- showing wherever it was reopened.
			clock.advance(ACTIVITY_GAP_SECONDS + 1)
			document.xpointer = "/body/DocFragment[9]"
			ui.view.state.page = 200
			tracker:endSession(document, ui, "suspend")

			local session = store.sessions[1]
			assert.are.equal(stopped_at, session.end_time)
			assert.are.equal(CAPTURE_INTERVAL_SECONDS, session.duration_seconds)
			-- Not recaptured: an end position taken now would be the wrong page,
			-- and one equal to the start makes the server drop the session.
			assert.are.equal("/body/DocFragment[3]", session.end_position)
			assert.are.equal(12, session.end_page)
		end)

		it("discards a sitting shorter than the configured minimum", function()
			local tracker, store, clock = trackerWith()
			local document = documentAt("/body/DocFragment[1]")
			local ui = uiFor(document, 1)

			tracker:startSession(document, ui)
			clock.advance(MIN_DURATION - 1)
			tracker:endSession(document, ui, "document_close")

			assert.are.equal(0, #store.sessions)
			assert.is_false(tracker:hasActiveSession())
		end)

		it("keeps a sitting of exactly the minimum", function()
			local tracker, store, clock = trackerWith()
			local document = documentAt("/body/DocFragment[1]")
			local ui = uiFor(document, 1)

			tracker:startSession(document, ui)
			clock.advance(MIN_DURATION)
			tracker:endSession(document, ui, "document_close")

			assert.are.equal(1, #store.sessions)
		end)

		it("does nothing without a session to end", function()
			local tracker, store = trackerWith()
			local document = documentAt("/body/DocFragment[1]")

			tracker:endSession(document, uiFor(document, 1), "document_close")

			assert.are.equal(0, #store.sessions)
		end)

		it("drops a session the store could not take, rather than raising", function()
			local store = FakeSessionStore:new()
			local tracker, _, clock = trackerWith({ store = store })
			local document = documentAt("/body/DocFragment[1]")
			local ui = uiFor(document, 1)

			tracker:startSession(document, ui)
			clock.advance(MIN_DURATION)
			store.fails_at = "saveSession"

			assert.has_no.errors(function()
				tracker:endSession(document, ui, "document_close")
			end)
			assert.is_false(tracker:hasActiveSession())
		end)
	end)

	describe("Page Views", function()
		it("records each page that was on screen, from its start to the next page's", function()
			local tracker, store, clock = trackerWith()
			local document = bookOpenAt(3)
			local ui = pageModeUiFor(document)

			tracker:startSession(document, ui)
			clock.advance(20)
			turnTo(tracker, document, ui, 4)
			clock.advance(50)
			tracker:endSession(document, ui, "document_close")

			assert.are.same({
				{
					start_xpoint = "/body/DocFragment[2]/p[3]@default",
					end_xpoint = "/body/DocFragment[2]/p[4]@default",
					shown_at = START_TIME,
					duration_seconds = 20,
				},
				{
					start_xpoint = "/body/DocFragment[2]/p[4]@default",
					end_xpoint = "/body/DocFragment[2]/p[5]@default",
					shown_at = START_TIME + 20,
					duration_seconds = 50,
				},
			}, store.sessions[1].page_views)
		end)

		it("ends the Page View at a relayout and starts one for the new layout", function()
			local tracker, store, clock = trackerWith()
			local document = bookOpenAt(3)
			local ui = pageModeUiFor(document)

			tracker:startSession(document, ui)
			clock.advance(30)
			-- A font change: KOReader re-renders, keeps the reader on the same
			-- page number and reports it again.
			document.layout = "bigger-font"
			turnTo(tracker, document, ui, 3)
			clock.advance(40)
			tracker:endSession(document, ui, "document_close")

			local page_views = store.sessions[1].page_views
			assert.are.equal(2, #page_views)
			assert.are.equal("/body/DocFragment[2]/p[4]@default", page_views[1].end_xpoint)
			assert.are.equal(30, page_views[1].duration_seconds)
			assert.are.equal("/body/DocFragment[2]/p[3]@bigger-font", page_views[2].start_xpoint)
			assert.are.equal("/body/DocFragment[2]/p[4]@bigger-font", page_views[2].end_xpoint)
			assert.are.equal(START_TIME + 30, page_views[2].shown_at)
			assert.are.equal(40, page_views[2].duration_seconds)
		end)

		it("keeps one Page View when the same screen is reported again", function()
			-- KOReader repeats PageUpdate for a screen that did not change, a
			-- font gamma change for one.
			local tracker, store, clock = trackerWith()
			local document = bookOpenAt(3)
			local ui = pageModeUiFor(document)

			tracker:startSession(document, ui)
			clock.advance(30)
			turnTo(tracker, document, ui, 3)
			clock.advance(40)
			tracker:endSession(document, ui, "document_close")

			assert.are.same({
				{
					start_xpoint = "/body/DocFragment[2]/p[3]@default",
					end_xpoint = "/body/DocFragment[2]/p[4]@default",
					shown_at = START_TIME,
					duration_seconds = 70,
				},
			}, store.sessions[1].page_views)
		end)

		it("counts no time asleep: a suspend ends the Page View and the resume starts another", function()
			-- What main.lua does on Suspend and Resume.
			local tracker, store, clock = trackerWith()
			local document = bookOpenAt(3)
			local ui = pageModeUiFor(document)

			tracker:startSession(document, ui)
			clock.advance(MIN_DURATION)
			tracker:endSession(document, ui, "suspend")
			clock.advance(600)
			tracker:startSession(document, ui)
			clock.advance(MIN_DURATION)
			tracker:endSession(document, ui, "suspend")

			assert.are.equal(2, #store.sessions)
			assert.are.same({
				{
					start_xpoint = "/body/DocFragment[2]/p[3]@default",
					end_xpoint = "/body/DocFragment[2]/p[4]@default",
					shown_at = START_TIME,
					duration_seconds = MIN_DURATION,
				},
			}, store.sessions[1].page_views)
			assert.are.same({
				{
					start_xpoint = "/body/DocFragment[2]/p[3]@default",
					end_xpoint = "/body/DocFragment[2]/p[4]@default",
					shown_at = START_TIME + MIN_DURATION + 600,
					duration_seconds = MIN_DURATION,
				},
			}, store.sessions[2].page_views)
		end)

		it("records no Page View for the book's last page, which has no next page to end at", function()
			local tracker, store, clock = trackerWith()
			local document = bookOpenAt(BOOK_PAGES - 1)
			local ui = pageModeUiFor(document)

			tracker:startSession(document, ui)
			clock.advance(20)
			turnTo(tracker, document, ui, BOOK_PAGES)
			clock.advance(MIN_DURATION)
			tracker:endSession(document, ui, "document_close")

			assert.are.same({
				{
					start_xpoint = "/body/DocFragment[2]/p[9]@default",
					end_xpoint = "/body/DocFragment[2]/p[10]@default",
					shown_at = START_TIME,
					duration_seconds = 20,
				},
			}, store.sessions[1].page_views)
		end)

		it("drops the open Page View of a session a gap ended at its last page turn", function()
			-- Its time on screen would be the idle gap, not reading, and the
			-- server would drop it for ending after its session.
			local tracker, store, clock = trackerWith()
			local document = bookOpenAt(3)
			local ui = pageModeUiFor(document)

			tracker:startSession(document, ui)
			clock.advance(40)
			turnTo(tracker, document, ui, 4)
			clock.advance(30)
			turnTo(tracker, document, ui, 5)
			clock.advance(ACTIVITY_GAP_SECONDS + 1)
			turnTo(tracker, document, ui, 6)

			assert.are.equal(1, #store.sessions)
			assert.are.same({
				{
					start_xpoint = "/body/DocFragment[2]/p[3]@default",
					end_xpoint = "/body/DocFragment[2]/p[4]@default",
					shown_at = START_TIME,
					duration_seconds = 40,
				},
				{
					start_xpoint = "/body/DocFragment[2]/p[4]@default",
					end_xpoint = "/body/DocFragment[2]/p[5]@default",
					shown_at = START_TIME + 40,
					duration_seconds = 30,
				},
			}, store.sessions[1].page_views)
		end)

		it("starts the sitting after a gap on the page it was picked up at", function()
			local tracker, store, clock = trackerWith()
			local document = bookOpenAt(3)
			local ui = pageModeUiFor(document)

			tracker:startSession(document, ui)
			clock.advance(MIN_DURATION)
			turnTo(tracker, document, ui, 4)
			clock.advance(ACTIVITY_GAP_SECONDS + 1)
			turnTo(tracker, document, ui, 6)
			local picked_up_at = clock.now()
			clock.advance(MIN_DURATION)
			tracker:endSession(document, ui, "document_close")

			assert.are.same({
				{
					start_xpoint = "/body/DocFragment[2]/p[6]@default",
					end_xpoint = "/body/DocFragment[2]/p[7]@default",
					shown_at = picked_up_at,
					duration_seconds = MIN_DURATION,
				},
			}, store.sessions[2].page_views)
		end)

		it("drops the open Page View when a session ends long after its last page turn", function()
			local tracker, store, clock = trackerWith()
			local document = bookOpenAt(3)
			local ui = pageModeUiFor(document)

			tracker:startSession(document, ui)
			clock.advance(MIN_DURATION)
			turnTo(tracker, document, ui, 4)
			clock.advance(ACTIVITY_GAP_SECONDS + 1)
			tracker:endSession(document, ui, "suspend")

			assert.are.equal(1, #store.sessions[1].page_views)
			assert.are.equal(MIN_DURATION, store.sessions[1].page_views[1].duration_seconds)
		end)

		it("records a two-page spread as one Page View, to where the next spread starts", function()
			-- With each column numbered, the spread on screen is pages 3 and 4.
			local tracker, store, clock = trackerWith()
			local document = bookOpenAt(3)
			document.visible_page_numbers = 2
			local ui = pageModeUiFor(document)

			tracker:startSession(document, ui)
			clock.advance(MIN_DURATION)
			tracker:endSession(document, ui, "document_close")

			assert.are.same({
				{
					start_xpoint = "/body/DocFragment[2]/p[3]@default",
					end_xpoint = "/body/DocFragment[2]/p[5]@default",
					shown_at = START_TIME,
					duration_seconds = MIN_DURATION,
				},
			}, store.sessions[1].page_views)
		end)

		it("records no Page View for a spread that reaches the book's last page", function()
			local tracker, store, clock = trackerWith()
			local document = bookOpenAt(BOOK_PAGES - 1)
			document.visible_page_numbers = 2
			local ui = pageModeUiFor(document)

			tracker:startSession(document, ui)
			clock.advance(MIN_DURATION)
			tracker:endSession(document, ui, "document_close")

			assert.are.same({}, store.sessions[1].page_views)
		end)

		it("records no Page View for a screen crengine cannot place", function()
			local tracker, store, clock = trackerWith()
			local document = bookOpenAt(3)
			document.getPageXPointer = function()
				return ""
			end
			local ui = pageModeUiFor(document)

			tracker:startSession(document, ui)
			clock.advance(MIN_DURATION)
			tracker:endSession(document, ui, "document_close")

			assert.are.same({}, store.sessions[1].page_views)
		end)

		it("opens no Page View when the UI cannot say which page is on screen", function()
			local tracker, store, clock = trackerWith()
			local document = bookOpenAt(3)
			local ui = pageModeUiFor(document)
			ui.view.state.page = nil

			tracker:startSession(document, ui)
			clock.advance(MIN_DURATION)
			tracker:endSession(document, ui, "document_close")

			assert.are.same({}, store.sessions[1].page_views)
		end)

		it("records no Page Views in scroll mode", function()
			local tracker, store, clock = trackerWith()
			local document = bookOpenAt(3)
			local ui = pageModeUiFor(document)
			ui.view.view_mode = "scroll"

			tracker:startSession(document, ui)
			clock.advance(20)
			turnTo(tracker, document, ui, 4)
			clock.advance(MIN_DURATION)
			tracker:endSession(document, ui, "document_close")

			assert.are.same({}, store.sessions[1].page_views)
		end)

		it("ends the open Page View when the reader switches to scroll mode", function()
			-- main.lua passes ChangeViewMode on as a position update with no
			-- page, which is what KOReader's scroll mode sends instead of
			-- PageUpdate.
			local tracker, store, clock = trackerWith()
			local document = bookOpenAt(3)
			local ui = pageModeUiFor(document)

			tracker:startSession(document, ui)
			clock.advance(20)
			ui.view.view_mode = "scroll"
			tracker:updatePosition(document, ui, nil)
			clock.advance(MIN_DURATION)
			tracker:endSession(document, ui, "document_close")

			assert.are.equal(1, #store.sessions[1].page_views)
			assert.are.equal(20, store.sessions[1].page_views[1].duration_seconds)
		end)

		it("records no Page Views for an EPUB opened as a paged document", function()
			local tracker, store, clock = trackerWith()
			local document = pagedDocument()
			local ui = uiFor(document, 3)
			ui.view.view_mode = "page"

			tracker:startSession(document, ui)
			clock.advance(20)
			tracker:updatePosition(document, ui, 4)
			clock.advance(MIN_DURATION)
			tracker:endSession(document, ui, "document_close")

			assert.are.same({}, store.sessions[1].page_views)
		end)
	end)

	describe("reading back what was saved", function()
		--- Save one finished session for a book
		-- @param tracker table The tracker
		-- @param clock table Its clock
		-- @param document table The document to read
		local function readFor(tracker, clock, document)
			local ui = uiFor(document, 1)
			tracker:startSession(document, ui)
			clock.advance(MIN_DURATION)
			tracker:endSession(document, ui, "document_close")
		end

		it("answers a book's unsynced sessions", function()
			local tracker, _, clock = trackerWith()
			local document = documentAt("/body/DocFragment[1]")

			readFor(tracker, clock, document)

			local sessions = tracker:getUnsyncedSessionsForBook("md5:" .. FILE)
			assert.are.equal(1, #sessions)
			-- What the upload sends: the store answers those columns and the id,
			-- not the whole row it wrote.
			assert.are.equal(START_TIME, sessions[1].start_time)
			assert.are.equal("xpointer", sessions[1].position_type)
			assert.are.equal("/body/DocFragment[1]", sessions[1].start_position)
			assert.is_not_nil(sessions[1].id)
			assert.is_nil(sessions[1].book_title)
		end)

		it("answers each session with its Page Views", function()
			local tracker, _, clock = trackerWith()
			local document = bookOpenAt(3)
			local ui = pageModeUiFor(document)

			tracker:startSession(document, ui)
			clock.advance(MIN_DURATION)
			tracker:endSession(document, ui, "document_close")

			local sessions = tracker:getUnsyncedSessionsForBook("md5:" .. FILE)
			assert.are.same({
				{
					start_xpoint = "/body/DocFragment[2]/p[3]@default",
					end_xpoint = "/body/DocFragment[2]/p[4]@default",
					shown_at = START_TIME,
					duration_seconds = MIN_DURATION,
				},
			}, sessions[1].page_views)
		end)

		it("stops answering the sessions the server has taken", function()
			local tracker, _, clock = trackerWith()
			local document = documentAt("/body/DocFragment[1]")

			readFor(tracker, clock, document)
			local sessions = tracker:getUnsyncedSessionsForBook("md5:" .. FILE)

			assert.is_true(tracker:markSessionsSynced({ sessions[1].id }))
			assert.are.same({}, tracker:getUnsyncedSessionsForBook("md5:" .. FILE))
		end)

		it("answers nothing when the store never opened", function()
			local store = FakeSessionStore:new()
			store.fails_at = "open"
			local tracker = trackerWith({ store = store })

			assert.are.same({}, tracker:getUnsyncedSessionsForBook("md5:" .. FILE))
			assert.is_false(tracker:markSessionsSynced({ 1 }))
		end)
	end)

	describe("close", function()
		it("closes the store and forgets the sitting in progress", function()
			local tracker, store = trackerWith()
			local document = documentAt("/body/DocFragment[1]")

			tracker:startSession(document, uiFor(document, 1))
			tracker:close()

			assert.is_true(store.closed)
			assert.is_false(tracker:hasActiveSession())
		end)
	end)
end)
