--[[
Sync Service Module for Crossbill Sync

Orchestrates the complete sync workflow including:
- Highlight extraction and upload
- Pulling the server's highlights back into the book
- Reading session upload
- EPUB file uploads

Extracted from main.lua to improve separation of concerns.
The main plugin handles lifecycle events and UI, while this
module handles the sync business logic.
]]

local logger = require("logger")
local BookMetadata = require("modules/book_metadata")
local DeviceIdentity = require("modules/device_identity")
local HighlightExtractor = require("modules/highlight_extractor")
local HighlightImporter = require("modules/highlight_importer")
local NoteEdits = require("modules/note_edits")

local SyncService = {}
SyncService.__index = SyncService

--- Create a new SyncService instance
-- Collaborators come in a table rather than positionally: a caller that wants
-- only some of them (a test, or a sync path that skips the digest refresh) can
-- name those instead of counting nils.
-- @param deps table Collaborators, all optional except api_client:
--   api_client ApiClient instance for server communication
--   file_uploader FileUploader instance for file uploads
--   session_tracker SessionTracker instance for reading sessions
--   settings Settings instance for configuration
--   digest_service DigestService instance for digest refresh
--   highlight_importer HighlightImporter instance for the pull
--   highlight_snapshot HighlightSnapshot ledger of the last applied pull
-- @return SyncService instance
function SyncService:new(deps)
	local instance = setmetatable({}, SyncService)
	instance.api_client = deps.api_client
	instance.file_uploader = deps.file_uploader
	instance.session_tracker = deps.session_tracker
	instance.settings = deps.settings
	instance.digest_service = deps.digest_service
	instance.highlight_importer = deps.highlight_importer
	instance.highlight_snapshot = deps.highlight_snapshot
	return instance
end

--- Sync result structure
-- @field success boolean Whether sync completed successfully
-- @field highlights_created number Number of new highlights synced
-- @field highlights_skipped number Number of duplicate highlights skipped
-- @field sessions_synced number Number of reading sessions synced
-- @field pull table|nil Importer result of the pull that followed the push
-- @field pull_error string|nil Why the pull did not happen
-- @field error string|nil Error message if sync failed

--- Execute the complete sync workflow for a book
-- @param ui table The KOReader UI context
-- @return table SyncResult with success status and counts
function SyncService:syncBook(ui)
	local result = {
		success = true,
		highlights_created = 0,
		highlights_skipped = 0,
		sessions_synced = 0,
		error = nil,
	}

	-- Extract book metadata
	local book_metadata = BookMetadata:new(ui)
	local book_data = book_metadata:extractBookData()
	local doc_path = book_metadata:getDocPath()

	-- Fetch or create book on server
	local server_metadata = self:_getServerBookMetadata(book_data.client_book_id)
	if not server_metadata then
		-- Book doesn't exist on server, create it
		logger.info("Crossbill SyncService: Book not found on server, creating it")
		local create_success, created_metadata, create_err = self.api_client:createBook(book_data)
		if not create_success then
			result.success = false
			result.error = create_err or "Failed to create book on server"
			return result
		end
		server_metadata = created_metadata
	end

	-- Upload files (EPUB)
	self:_syncFiles(book_data.client_book_id, book_metadata, server_metadata)

	-- Stamp notes edited since the last sync, before they are extracted
	self:_stampNoteEdits(ui)

	-- Extract and upload highlights
	local highlight_result = self:_syncHighlights(ui, book_data.client_book_id, doc_path)
	if not highlight_result.success then
		result.success = false
		result.error = highlight_result.error
		return result
	end
	result.highlights_created = highlight_result.created
	result.highlights_skipped = highlight_result.skipped

	-- Bring the server's copy back (best-effort; never fails the sync)
	self:_applyPull(result, ui, book_data.client_book_id)

	-- Upload reading sessions
	local session_result = self:_syncReadingSessions(ui, book_data.client_book_id, doc_path)
	result.sessions_synced = session_result.synced

	-- Refresh cached digests (best-effort; never fails the sync)
	self:_refreshDigest(book_data.client_book_id)

	return result
end

--- Stamp the highlights whose note was edited since the last sync
-- Extraction reads the in-memory annotations, so the stamps have to be in place
-- before the highlights are collected for upload.
-- @param ui table The KOReader UI context
function SyncService:_stampNoteEdits(ui)
	if not ui.annotation or not ui.annotation.annotations then
		return
	end

	local stamped = NoteEdits.stamp(ui.annotation.annotations)
	if stamped > 0 then
		logger.info("Crossbill SyncService: Stamped", stamped, "edited notes")
	end
end

--- Fetch the server's highlights and write them into the open book
-- @param ui table The KOReader UI context
-- @param client_book_id string The client book ID
-- @return table|nil Importer result, or nil when nothing was pulled
-- @return string|nil Error message
function SyncService:_pullHighlights(ui, client_book_id)
	if not self.highlight_importer then
		return nil, "No highlight importer available"
	end

	local code, items, err = self.api_client:getHighlights(client_book_id)
	if code ~= 200 or not items then
		if code == 404 then
			return nil, "Book not found on Crossbill"
		end
		return nil, err or ("Fetch failed: " .. tostring(code))
	end

	return self.highlight_importer:replaceHighlights(ui, items)
end

--- Record the pull's outcome on the sync result
-- A failed pull is reported but never fails the sync: the push already
-- succeeded, and an autosync runs while the book is being torn down.
-- @param result table The sync result to fill in
-- @param ui table The KOReader UI context
-- @param client_book_id string The client book ID
function SyncService:_applyPull(result, ui, client_book_id)
	if not HighlightImporter.isSupportedBook(ui) then
		-- A book the importer cannot place highlights into is not a failure, so
		-- it is not worth reporting to the user.
		logger.dbg("Crossbill SyncService: No highlight pull for a fixed-layout book")
		return
	end

	local ok, pull_result, pull_err = pcall(function()
		return self:_pullHighlights(ui, client_book_id)
	end)

	if not ok then
		result.pull_error = tostring(pull_result)
	elseif pull_result then
		result.pull = pull_result
		self:_recordSnapshot(client_book_id, pull_result.placed)
	else
		result.pull_error = pull_err or "Highlight pull failed"
	end

	if result.pull_error then
		logger.warn("Crossbill SyncService: Highlight pull failed:", result.pull_error)
	end
end

--- Remember the highlights the pull just placed in the book
-- Only a pull that reached the book gets recorded, so an aborted one leaves the
-- previous snapshot describing the state the device is actually in. Like the
-- digest refresh, this is bookkeeping: it never fails a sync whose push already
-- succeeded.
-- @param client_book_id string The client book ID
-- @param placed table|nil Array of {server_id, text} the importer reported
function SyncService:_recordSnapshot(client_book_id, placed)
	if not self.highlight_snapshot or not placed then
		return
	end

	local ok, err = pcall(function()
		self.highlight_snapshot:recordPlaced(client_book_id, placed)
	end)

	if not ok then
		logger.warn("Crossbill SyncService: Failed to record the highlight snapshot:", err)
	end
end

--- Refresh a book's cached digests after a successful sync
-- Delegates to the digest service. Failures are logged only and never
-- propagate to the sync result.
-- @param client_book_id string The client book ID
function SyncService:_refreshDigest(client_book_id)
	if not self.digest_service then
		return
	end

	local ok, err = pcall(function()
		local refreshed, err_kind = self.digest_service:refreshBook(client_book_id)
		if not refreshed then
			logger.warn("Crossbill SyncService: Digest refresh skipped:", err_kind or "unknown")
		else
			logger.dbg("Crossbill SyncService: Digest refreshed for", client_book_id)
		end
	end)

	if not ok then
		logger.warn("Crossbill SyncService: Error refreshing digests:", err)
	end
end

--- Sync highlights for the current book
-- @param ui table The KOReader UI context
-- @param book_data table Book metadata
-- @param doc_path string Document file path
-- @return table Result with success, created, skipped, error
function SyncService:_syncHighlights(ui, client_book_id, doc_path)
	local result = { success = true, created = 0, skipped = 0, error = nil }

	-- Extract highlights
	local highlight_extractor = HighlightExtractor:new(ui)
	local highlights = highlight_extractor:getHighlights(doc_path)

	if not highlights or #highlights == 0 then
		logger.dbg("Crossbill SyncService: No highlights found")
		return result
	end

	logger.dbg("Crossbill SyncService: Found", #highlights, "highlights")

	-- Add chapter numbers to highlights
	highlight_extractor:addChapterNumbers(highlights)

	-- Upload highlights to server
	local upload_success, response, err =
		self.api_client:uploadHighlights(client_book_id, highlights, DeviceIdentity.getDeviceId())

	if not upload_success then
		result.success = false
		result.error = err
		return result
	end

	if response then
		result.created = response.highlights_created or 0
		result.skipped = response.highlights_skipped or 0
	end

	return result
end

--- Sync reading sessions for the current book
-- @param ui table The KOReader UI context
-- @param client_book_id client book ide
-- @param doc_path string Document file path
-- @return table Result with success, synced, error
function SyncService:_syncReadingSessions(ui, client_book_id, doc_path)
	local result = { success = true, synced = 0, error = nil }

	if not self.session_tracker or not self.settings:isSessionTrackingEnabled() then
		logger.dbg("Crossbill SyncService: Session tracking not enabled")
		return result
	end

	if not doc_path then
		logger.warn("Crossbill SyncService: Cannot get document path for session sync")
		return result
	end

	-- Get book file hash using SessionTracker's method for consistency
	local book_file_hash = self.session_tracker:getBookFileHash(doc_path)

	-- Get unsynced sessions for this book only
	local sessions = self.session_tracker:getUnsyncedSessionsForBook(book_file_hash)
	if #sessions == 0 then
		logger.dbg("Crossbill SyncService: No reading sessions to sync for current book")
		return result
	end

	logger.info("Crossbill SyncService: Found", #sessions, "unsynced reading sessions")

	local success, response, err = self.api_client:uploadReadingSessions(client_book_id, sessions)
	if success and response then
		-- Mark all sessions as synced (all-or-nothing API)
		local session_ids = {}
		for _, session in ipairs(sessions) do
			table.insert(session_ids, session.id)
		end
		self.session_tracker:markSessionsSynced(session_ids)

		logger.info("Crossbill SyncService: Synced", #sessions, "reading sessions")
		result.synced = #sessions
	else
		-- On failure, sessions remain unsynced for retry
		logger.warn("Crossbill SyncService: Failed to sync reading sessions:", err)
		result.success = false
		result.error = err
	end

	return result
end

--- Sync files (EPUB) for the current book
-- @param client_book_id string The client book ID
-- @param book_metadata BookMetadata instance
-- @param server_metadata table Server metadata containing has_ebook, etc.
function SyncService:_syncFiles(client_book_id, book_metadata, server_metadata)
	-- Upload EPUB file if available (errors are logged but don't fail sync)
	local epub_ok, epub_err = self.file_uploader:uploadEpub(client_book_id, book_metadata, server_metadata)
	if not epub_ok then
		logger.warn("Crossbill SyncService: EPUB upload issue:", epub_err)
	end
end

--- Fetch book metadata from the server
-- @param client_book_id string The client book ID (hash of title|author)
-- @return table|nil Server metadata containing has_ebook, etc. or nil if not found
function SyncService:_getServerBookMetadata(client_book_id)
	local code, metadata, _ = self.api_client:getBookMetadata(client_book_id)

	if code == 404 then
		logger.dbg("Crossbill SyncService: Book not found on server")
		return nil
	end

	if not metadata then
		logger.warn("Crossbill SyncService: Failed to fetch book metadata from server")
		return nil
	end

	return metadata
end

return SyncService
