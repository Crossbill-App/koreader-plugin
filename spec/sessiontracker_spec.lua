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
