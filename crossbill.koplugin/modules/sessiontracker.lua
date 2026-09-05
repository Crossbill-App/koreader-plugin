--[[
Session Tracker Module for Crossbill Sync

Decides what a reading session is: when one starts, where the reader had got to
when it stopped, and when a gap means it stopped long before anyone noticed.
Device-independent position data (XPointers for reflowable docs, page numbers
for fixed-layout docs) is what it records, for later sync and analytics.

Where the sessions are kept is `modules/session_store`'s business, and it
arrives as a dependency: specs stand an in-memory store in its place, so none of
the reasoning below needs the reader's SQLite binding to be exercised. The clock
arrives the same way, because a gap and a throttle are both read off it.
]]

local logger = require("logger")
local BookIdentity = require("modules/book_identity")
local BookMetadata = require("modules/book_metadata")
local DeviceIdentity = require("modules/device_identity")

local SessionTracker = {}
SessionTracker.__index = SessionTracker

-- A gap this long between page turns means reading stopped: the reader put the
-- book down, or the device suspended without telling us (onSuspend is not
-- reliable on PocketBook). Such a session is ended as of its last activity
-- instead of running until the device finally powers off.
local SESSION_ACTIVITY_GAP_SECONDS = 1800

-- How often a page turn triggers a full position capture. Page turns are
-- frequent and the capture is not free, but without it the tracked xpointer
-- would never move during a session.
local POSITION_CAPTURE_INTERVAL_SECONDS = 60

--- Ask the store for something without letting it raise
-- Every path below is reached from a KOReader event handler, and a page turn
-- that ends in an error is a page turn the reader loses, so a store that blows
-- up is logged and answered as nothing.
-- @param what string What was being asked, for the log line
-- @param fn function Makes the call and returns its answer
-- @return any The store's answer, nil when the call raised
local function guarded(what, fn)
	local ok, answer = pcall(fn)
	if not ok then
		logger.err("Crossbill SessionTracker: The store failed to", what .. ":", answer)
		return nil
	end
	return answer
end

--- Create a new SessionTracker instance
-- @param deps table Collaborators:
--   settings Settings instance for accessing configuration
--   store The session store to keep finished sessions in
--   now function|nil Reads the clock, defaulting to os.time
-- @return SessionTracker instance
function SessionTracker:new(deps)
	local instance = setmetatable({}, SessionTracker)
	instance.settings = deps and deps.settings
	instance.store = deps and deps.store
	instance.now = (deps and deps.now) or os.time
	instance.current_session = nil
	instance._initialized = false
	return instance
end

--- Open the tracker's storage
-- @param data_dir string Path to KOReader's settings directory
-- @return boolean Success status
function SessionTracker:init(data_dir)
	if self._initialized then
		return true
	end

	if not self.store then
		logger.warn("Crossbill SessionTracker: No store to open")
		return false
	end

	local opened = guarded("open", function()
		return self.store:open(data_dir)
	end)

	if not opened then
		logger.err("Crossbill SessionTracker: The store would not open")
		return false
	end

	self._initialized = true
	logger.dbg("Crossbill SessionTracker: Tracking sessions")
	return true
end

--- Close the tracker's storage
function SessionTracker:close()
	if self._initialized then
		guarded("close", function()
			self.store:close()
		end)
	end

	self._initialized = false
	self.current_session = nil
end

--- Capture current reading position from document
-- There is no fixed-layout branch here because there are no fixed-layout
-- documents to reach it: `modules/document_support` keeps the whole plugin
-- inert on anything but an EPUB (see `main.lua:init`), so every document that
-- gets this far is reflowable and has an XPointer to record.
-- @param document The document object
-- @param ui The UI object
-- @return table Position data {type, position, page}
function SessionTracker:_capturePosition(document, ui)
	if not document then
		return nil
	end

	local position_data = {
		type = "xpointer",
		position = "0",
		page = 0,
	}

	local success, err = pcall(function()
		local xpointer = document:getXPointer()
		if xpointer then
			position_data.position = xpointer
		end
		-- Also capture page for reference
		if ui and ui.view and ui.view.state and ui.view.state.page then
			position_data.page = ui.view.state.page
		end
	end)

	if not success then
		logger.warn("Crossbill SessionTracker: Error capturing position:", err)
	end

	return position_data
end

--- Get total pages in document
-- @param document The document object
-- @return number Total pages or 0
function SessionTracker:_getTotalPages(document)
	if not document or not document.getPageCount then
		return 0
	end

	return document:getPageCount() or 0
end

--- Start tracking a new reading session
-- @param document The document object
-- @param ui The UI object
function SessionTracker:startSession(document, ui)
	if not self._initialized then
		logger.warn("Crossbill SessionTracker: Cannot start session - not initialized")
		return
	end

	if not document then
		logger.warn("Crossbill SessionTracker: Cannot start session - no document")
		return
	end

	-- If there's already an active session, end it first
	if self.current_session then
		logger.dbg("Crossbill SessionTracker: Ending previous session before starting new one")
		self:endSession(document, ui, "new_session")
	end

	local file_path = document.file or ""
	-- Sessions are stored and uploaded under this hash, so a document with no
	-- file to hash has no session worth recording: every such document would
	-- otherwise share one identity and be uploaded as a single book.
	local book_hash = BookIdentity.fileHash(file_path)
	if not book_hash then
		logger.warn("Crossbill SessionTracker: Cannot start session - document has no file path")
		return
	end

	local position = self:_capturePosition(document, ui)

	if not position then
		logger.warn("Crossbill SessionTracker: Cannot capture start position")
		return
	end

	-- Title and author for the session row, from the metadata extractor first
	-- and the document's own properties second. Either reaches into a document
	-- that may not hold what it expects -- the extractor needs doc_props, which
	-- is missing outside normal reading -- and a session is not worth losing
	-- over that, so each is asked under a guard and only what is still missing
	-- is asked of the next.
	local book_title, book_author
	local failure

	--- Fill in whichever of the title and author is still missing
	-- @param read function Answers the title and the author, or raises
	local function fillFrom(read)
		if book_title and book_author then
			return
		end

		local ok, title, author = pcall(read)
		if not ok then
			failure = title
			return
		end
		if not book_title and title and title ~= "" then
			book_title = title
		end
		if not book_author and author and author ~= "" then
			book_author = author
		end
	end

	if ui then
		fillFrom(function()
			local book_data = BookMetadata:new(ui):extractBookData() or {}
			return book_data.title, book_data.author
		end)
	end
	fillFrom(function()
		local props = document:getProps() or {}
		return props.title, props.authors
	end)

	if failure and (not book_title or not book_author) then
		logger.warn("Crossbill SessionTracker: Could not read the book's title and author:", failure)
	end

	local now = self.now()

	self.current_session = {
		book_file = file_path,
		book_hash = book_hash,
		book_title = book_title,
		book_author = book_author,
		start_time = now,
		start_position = position.position,
		start_page = position.page,
		position_type = position.type,
		-- These will be updated as reading progresses
		current_position = position.position,
		current_page = position.page,
		last_activity_time = now,
		last_capture_time = now,
		total_pages = self:_getTotalPages(document),
	}

	logger.dbg("Crossbill SessionTracker: Started session for", book_title or file_path)
end

--- Update current reading position (called on every page turn)
-- This should be fast as it's called frequently
-- @param document The document object
-- @param ui The UI object
-- @param pageno number Current page number (optional)
function SessionTracker:updatePosition(document, ui, pageno)
	local session = self.current_session
	if not session then
		return
	end

	local now = self.now()
	local idle_seconds = now - (session.last_activity_time or session.start_time)

	-- A long gap means this page turn belongs to a new sitting, not the old
	-- one: close the old session where and when it actually stopped.
	if idle_seconds > SESSION_ACTIVITY_GAP_SECONDS then
		logger.dbg("Crossbill SessionTracker: Activity gap of", idle_seconds, "seconds - splitting session")
		self:_endSessionAtLastActivity("activity_gap")
		self:startSession(document, ui)
		session = self.current_session
		if not session then
			return
		end
		now = session.last_activity_time
	end

	-- Full position capture is throttled: page turns are frequent, but the
	-- tracked position has to keep up so a retroactive end has somewhere to
	-- point at.
	if not pageno or (now - (session.last_capture_time or 0)) >= POSITION_CAPTURE_INTERVAL_SECONDS then
		local position = self:_capturePosition(document, ui)
		if position then
			session.current_position = position.position
			session.current_page = position.page
		end
		session.last_capture_time = now
	end

	-- Quick update without full position capture for performance
	if pageno then
		session.current_page = pageno
	end

	session.last_activity_time = now
end

--- Save a finished session to the store
-- Shared by both end paths (fresh capture and retroactive end); the caller
-- decides when the session ended and where it ended.
-- @param session table The session being ended
-- @param end_time number Unix time the session ended
-- @param end_position string Position where reading stopped
-- @param end_page number Page where reading stopped
-- @param reason string Reason for ending
function SessionTracker:_saveSession(session, end_time, end_position, end_page, reason)
	if not self._initialized then
		logger.warn("Crossbill SessionTracker: Cannot save session - store not available")
		return
	end

	local duration = end_time - session.start_time

	-- Discard very short sessions
	local min_duration = self.settings:getMinReadingSessionDuration() or 60
	if duration < min_duration then
		logger.dbg("Crossbill SessionTracker: Discarding short session (", duration, "seconds) - reason:", reason)
		return
	end

	local saved = guarded("save a session", function()
		return self.store:saveSession({
			book_file = session.book_file,
			book_hash = session.book_hash,
			book_title = session.book_title,
			book_author = session.book_author,
			start_time = session.start_time,
			end_time = end_time,
			duration_seconds = duration,
			position_type = session.position_type,
			start_position = session.start_position,
			end_position = end_position,
			start_page = session.start_page,
			end_page = end_page,
			total_pages = session.total_pages,
			device_id = DeviceIdentity.getDeviceId(),
		})
	end)

	if saved then
		logger.dbg("Crossbill SessionTracker: Saved session (", duration, "seconds) - reason:", reason)
	else
		logger.err("Crossbill SessionTracker: Failed to save session - reason:", reason)
	end
end

--- End the active session as of its last recorded activity
-- Used when reading stopped long before we noticed (an idle gap, or a suspend
-- that never reached us). The position is not re-captured: the document now
-- shows where the reader is *now*, which may be hours of standby later, and an
-- end position equal to the start position makes the server drop the session.
-- @param reason string Reason for ending
function SessionTracker:_endSessionAtLastActivity(reason)
	local session = self.current_session
	if not session then
		return
	end

	local end_time = session.last_activity_time or session.start_time
	self:_saveSession(session, end_time, session.current_position, session.current_page, reason)
	self.current_session = nil
end

--- End current session and save it
-- @param document The document object
-- @param ui The UI object
-- @param reason string Reason for ending ("document_close", "suspend", "app_exit", "new_session")
function SessionTracker:endSession(document, ui, reason)
	local session = self.current_session
	if not session then
		logger.dbg("Crossbill SessionTracker: No active session to end")
		return
	end

	if not self._initialized then
		logger.warn("Crossbill SessionTracker: Cannot end session - store not available")
		self.current_session = nil
		return
	end

	local end_time = self.now()
	local idle_seconds = end_time - (session.last_activity_time or session.start_time)

	-- Reading stopped long ago; end the session there rather than now.
	if idle_seconds > SESSION_ACTIVITY_GAP_SECONDS then
		logger.dbg(
			"Crossbill SessionTracker: Ending session at last activity,",
			idle_seconds,
			"seconds ago - reason:",
			reason
		)
		self:_endSessionAtLastActivity(reason)
		return
	end

	-- Capture final position
	local end_position = session.current_position
	local end_page = session.current_page

	if document then
		local position = self:_capturePosition(document, ui)
		if position then
			end_position = position.position
			end_page = position.page
		end
	end

	self:_saveSession(session, end_time, end_position, end_page, reason)
	self.current_session = nil
end

--- Mark sessions as synced
-- @param session_ids table Array of session IDs to mark as synced
-- @return boolean Success status
function SessionTracker:markSessionsSynced(session_ids)
	if not self._initialized then
		return false
	end

	return guarded("mark sessions as synced", function()
		return self.store:markSessionsSynced(session_ids)
	end) or false
end

--- Get unsynced sessions for a specific book
-- @param book_file_hash string MD5 hash of the book file path
-- @return table Array of session records for API upload
function SessionTracker:getUnsyncedSessionsForBook(book_file_hash)
	if not self._initialized then
		return {}
	end

	return guarded("read a book's unsynced sessions", function()
		return self.store:getUnsyncedSessionsForBook(book_file_hash)
	end) or {}
end

--- Check if there's an active session
-- @return boolean True if session is active
function SessionTracker:hasActiveSession()
	return self.current_session ~= nil
end

return SessionTracker
