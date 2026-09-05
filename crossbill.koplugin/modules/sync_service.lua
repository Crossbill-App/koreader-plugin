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
local BookIdentity = require("modules/book_identity")
local BookMetadata = require("modules/book_metadata")
local DeviceIdentity = require("modules/device_identity")
local DocumentSupport = require("modules/document_support")
local HighlightExtractor = require("modules/highlight_extractor")
local HighlightImporter = require("modules/highlight_importer")
local NoteEdits = require("modules/note_edits")
local UpgradeRequired = require("modules/upgrade_required")

local SyncService = {}
SyncService.__index = SyncService

--- Read a whole file, the default behind the injected reader
-- @param path string The file to read
-- @return string|nil The file's bytes, nil when it could not be read
-- @return string|nil Why it could not be read
local function readWholeFile(path)
	local file, open_err = io.open(path, "rb")
	if not file then
		return nil, open_err or "Failed to open file"
	end

	local data = file:read("*all")
	file:close()
	return data
end

--- Create a new SyncService instance
-- Collaborators come in a table rather than positionally: a caller that wants
-- only some of them (a test, or a sync path that skips the digest refresh) can
-- name those instead of counting nils.
-- @param deps table Collaborators, all optional except api_client:
--   api_client ApiClient instance for server communication
--   session_tracker SessionTracker instance for reading sessions
--   settings Settings instance for configuration
--   digest_service DigestService instance for digest refresh
--   highlight_importer HighlightImporter instance for the pull
--   highlight_snapshot HighlightSnapshot ledger of the last applied pull
--   read_file function(path) -> data|nil, err, the one thing this service does
--     to the filesystem, injectable so a spec can hand it an EPUB without
--     putting one on disk. Called as a plain function, not a method.
-- @return SyncService instance
function SyncService:new(deps)
	local instance = setmetatable({}, SyncService)
	instance.api_client = deps.api_client
	instance.read_file = deps.read_file or readWholeFile
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
-- @field highlights_removed number Number of highlights withdrawn from devices
-- @field sessions_synced number Number of reading sessions synced
-- @field pull table|nil Importer result of the pull that followed the push
-- @field pull_error string|nil Why the pull did not happen
-- @field error string|nil Error message if sync failed
-- @field upgrade_required table|nil The server's refusal to serve this plugin
--   version, which the sync has already handed to opts.on_upgrade_required

--- Hand the refusal to whoever can put it in front of the reader
-- Reported from within the sync because an autosync's return value has nobody
-- watching it, and through the caller's callback because this service knows
-- nothing about screens. A sync with nobody to tell still stops, quietly.
-- @param err table The refusal
-- @param opts table|nil Sync options; see syncBook
function SyncService:_reportRefusal(err, opts)
	local report = opts and opts.on_upgrade_required
	if not report then
		logger.dbg("Crossbill SyncService: Nobody to tell that the server refuses this plugin version")
		return
	end

	local ok, report_err = pcall(report, err)
	if not ok then
		logger.warn("Crossbill SyncService: Reporting the refusal failed:", report_err)
	end
end

--- Execute the complete sync workflow for a book
-- The server's refusal to serve this plugin version is raised by the api client
-- rather than returned, and caught here, once, for the whole attempt: the first
-- refusal ends the sync where it stands, because the remaining calls would only
-- collect the same answer and half a sync is worse than none. Catching it in one
-- place is what lets the steps below read as the plain sequence they are.
-- @param ui table The KOReader UI context
-- @param opts table|nil Options for this sync:
--   confirm_removal function(count) -> boolean, asked before every highlight of
--     a book is withdrawn from the reader's devices. Absent means nobody can be
--     asked, and the mass removal is skipped.
--   on_upgrade_required function(err), called at most once per attempt with the
--     server's refusal to serve this plugin version. Absent means the refusal is
--     only reported in the result.
-- @return table SyncResult with success status and counts
function SyncService:syncBook(ui, opts)
	local result = {
		success = true,
		highlights_created = 0,
		highlights_skipped = 0,
		highlights_removed = 0,
		sessions_synced = 0,
		error = nil,
	}

	local ok, err = pcall(function()
		self:_runSyncSteps(result, ui, opts)
	end)
	if ok then
		return result
	end

	if not UpgradeRequired.is(err) then
		-- Every other error is the caller's to report as it always was: main.lua
		-- wraps the sync in a pcall of its own, and this one must not swallow
		-- what that one exists to catch.
		error(err, 0)
	end

	logger.warn("Crossbill SyncService: The server refuses this plugin version, abandoning the sync")
	self:_reportRefusal(err, opts)
	result.success = false
	result.upgrade_required = err
	result.error = UpgradeRequired.message(err)
	return result
end

--- Walk the sync's steps in order, filling in the result as they succeed
-- Nothing here watches for the server's refusal: it is raised out of whichever
-- call meets it and caught by syncBook.
-- @param result table The sync result to fill in
-- @param ui table The KOReader UI context
-- @param opts table|nil Sync options; see syncBook
function SyncService:_runSyncSteps(result, ui, opts)
	-- Extract book metadata
	local book_metadata = BookMetadata:new(ui)
	local book_data = book_metadata:extractBookData()
	local doc_path = book_metadata:getDocPath()

	-- Fetch or create book on server
	local server_metadata, metadata_err = self:_getServerBookMetadata(book_data.client_book_id)
	if metadata_err then
		-- A fetch that failed for any reason other than "no such book" says
		-- nothing about whether the book is there, so creating one would only
		-- meet the same failure a step later and report it from further away.
		result.success = false
		result.error = metadata_err
		return
	end

	if not server_metadata then
		-- Book doesn't exist on server, create it
		logger.info("Crossbill SyncService: Book not found on server, creating it")
		local create_code, created_metadata, create_err = self.api_client:createBook(book_data)
		if create_code ~= 200 then
			result.success = false
			result.error = create_err or "Failed to create book on server"
			return
		end
		server_metadata = created_metadata
	end

	-- Upload files (EPUB)
	self:_syncFiles(book_data.client_book_id, book_metadata, server_metadata)

	-- Stamp notes edited since the last sync, before they are extracted
	self:_stampNoteEdits(ui)

	-- Extract and upload highlights, together with what was deleted here
	local highlight_result = self:_syncHighlights(ui, book_data.client_book_id, doc_path, opts)
	if not highlight_result.success then
		result.success = false
		result.error = highlight_result.error
		return
	end
	result.highlights_created = highlight_result.created
	result.highlights_skipped = highlight_result.skipped
	result.highlights_removed = highlight_result.removed

	-- Bring the server's copy back (best-effort; never fails the sync). The push
	-- above already carried the removals, so this replace confirms them instead
	-- of handing the deleted highlights back to the device.
	self:_applyPull(result, ui, book_data.client_book_id, doc_path)

	-- Upload reading sessions
	local session_result = self:_syncReadingSessions(ui, book_data.client_book_id, doc_path)
	result.sessions_synced = session_result.synced

	-- Refresh cached digests (best-effort; never fails the sync)
	self:_refreshDigest(book_data.client_book_id)
end

--- Run a step whose failure is not worth failing the sync over
-- The push has already succeeded by the time most of these run, and an autosync
-- runs while the book is being torn down, so bookkeeping that blows up is logged
-- and forgotten. The one exception is the server's refusal to serve this plugin
-- version: that is not about the step at all, and swallowing it here would leave
-- the reader syncing into a server that answers nothing. Stated once, so no
-- individual pcall has to remember it.
-- @param label string What went wrong, for the log line the failure gets
-- @param fn function The work to attempt, raising whatever went wrong
-- @param default any What to answer with when it failed
-- @return any The work's return value, or `default` when it failed
-- @return string|nil What it failed with, nil when it did not fail
function SyncService:_bookkeeping(label, fn, default)
	local ok, value = pcall(fn)
	if ok then
		return value, nil
	end

	if UpgradeRequired.is(value) then
		error(value, 0)
	end

	logger.warn("Crossbill SyncService: " .. label .. ":", value)
	return default, tostring(value)
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
-- @param doc_path string|nil Document file path, which the snapshot is recorded
--   against so the next sync knows whose diff it may trust
function SyncService:_applyPull(result, ui, client_book_id, doc_path)
	if not HighlightImporter.isSupportedBook(ui) then
		-- A book the importer cannot place highlights into is not a failure, so
		-- it is not worth reporting to the user.
		logger.dbg("Crossbill SyncService: No highlight pull for a fixed-layout book")
		return
	end

	local pull_result, pull_err = self:_bookkeeping("Highlight pull failed", function()
		local pulled, failed = self:_pullHighlights(ui, client_book_id)
		if not pulled then
			-- A pull that came back with a reason and one that blew up are the
			-- same news, so the reason is raised too and both leave by the one
			-- door the refusal cannot be swallowed behind.
			error(failed or "Highlight pull failed", 0)
		end
		return pulled
	end)

	if not pull_result then
		result.pull_error = pull_err
		return
	end

	result.pull = pull_result
	self:_recordSnapshot(client_book_id, pull_result.placed, BookIdentity.fileHash(doc_path))
end

--- Remember the highlights the pull just placed in the book
-- Only a pull that reached the book gets recorded, so an aborted one leaves the
-- previous snapshot describing the state the device is actually in. Like the
-- digest refresh, this is bookkeeping: it never fails a sync whose push already
-- succeeded.
-- @param client_book_id string The client book ID
-- @param placed table|nil Array of {server_id, text} the importer reported
-- @param book_file_hash string|nil Hash of the file the pull went into, which
--   takes ownership of the snapshot from whichever copy held it before
function SyncService:_recordSnapshot(client_book_id, placed, book_file_hash)
	if not self.highlight_snapshot or not placed then
		return
	end

	self:_bookkeeping("Failed to record the highlight snapshot", function()
		self.highlight_snapshot:recordPlaced(client_book_id, placed, book_file_hash)
	end)
end

--- Refresh a book's cached digests after a successful sync
-- Delegates to the digest service. Failures are logged only and never propagate
-- to the sync result, except the server's refusal to serve this plugin version,
-- which the digest service raises and syncBook catches.
-- @param client_book_id string The client book ID
function SyncService:_refreshDigest(client_book_id)
	if not self.digest_service then
		return
	end

	self:_bookkeeping("Error refreshing digests", function()
		local refreshed, err_kind = self.digest_service:refreshBook(client_book_id)
		if not refreshed then
			logger.warn("Crossbill SyncService: Digest refresh skipped:", err_kind or "unknown")
			return
		end

		logger.dbg("Crossbill SyncService: Digest refreshed for", client_book_id)
	end)
end

--- Sync highlights for the current book
-- @param ui table The KOReader UI context
-- @param client_book_id string The client book ID
-- @param doc_path string Document file path
-- @param opts table|nil Sync options; see syncBook
-- @return table Result with success, created, skipped, removed, error
function SyncService:_syncHighlights(ui, client_book_id, doc_path, opts)
	local result = { success = true, created = 0, skipped = 0, removed = 0, error = nil }

	-- Extract highlights
	local highlight_extractor = HighlightExtractor:new(ui)
	local highlights = highlight_extractor:getHighlights(doc_path) or {}

	logger.dbg("Crossbill SyncService: Found", #highlights, "highlights")

	if #highlights > 0 then
		-- Add chapter numbers to highlights
		highlight_extractor:addChapterNumbers(highlights)
	end

	-- The ledger is shared by every copy of the book, but only this file's own
	-- snapshot says anything about what this file has lost or gained.
	local book_file_hash = BookIdentity.fileHash(doc_path)

	-- Whatever the ledger remembers but the book no longer holds was deleted here
	local removed_ids = self:_removedHighlightIds(client_book_id, highlights, book_file_hash, opts)

	if #highlights == 0 and #removed_ids == 0 then
		logger.dbg("Crossbill SyncService: Nothing to push")
		return result
	end

	-- Whatever the book holds that the ledger never pulled was made here
	self:_flagNewHighlights(client_book_id, highlights, book_file_hash)

	-- Upload highlights to server
	local upload_code, response, err =
		self.api_client:uploadHighlights(client_book_id, highlights, DeviceIdentity.getDeviceId(), removed_ids)

	if upload_code ~= 200 then
		-- The removals stay unsent, and the snapshot only moves on after a
		-- successful pull, so the next sync diffs them out again.
		result.success = false
		result.error = err
		return result
	end

	if response then
		result.created = response.highlights_created or 0
		result.skipped = response.highlights_skipped or 0
		result.removed = response.highlights_removed or 0
	end

	return result
end

--- Mark the highlights this device made itself before they are pushed
-- A flagged highlight tells the server the reader highlighted the passage
-- deliberately, so a copy it had removed or deleted is revived rather than
-- swallowed as a stale echo. Like the diff, this leans on the ledger: a book
-- that has never pulled, or whose snapshot another copy of it recorded, flags
-- nothing and pushes exactly as it did before.
-- @param client_book_id string The client book ID
-- @param highlights table The highlights about to be pushed, flagged in place
-- @param book_file_hash string|nil Hash of the file being synced
function SyncService:_flagNewHighlights(client_book_id, highlights, book_file_hash)
	if not self.highlight_snapshot then
		return
	end

	-- Unflagged highlights are the old behaviour, which is worth more than a sync
	-- that fails over bookkeeping.
	local flagged = self:_bookkeeping("Failed to flag new highlights", function()
		return self.highlight_snapshot:flagNew(client_book_id, highlights, book_file_hash)
	end, 0)

	if flagged > 0 then
		logger.info("Crossbill SyncService: Flagging", flagged, "highlights as new on this device")
	end
end

--- Work out which of the book's server highlights were deleted on this device
-- The answer comes from this file's own snapshot, so a book with none of its
-- own -- a first sync, a fixed-layout book, or a second copy of a book another
-- file has pulled -- reports nothing and behaves exactly as it did before
-- removals existed. The pull at the end of this sync gives it one.
-- @param client_book_id string The client book ID
-- @param highlights table The highlights currently in the book
-- @param book_file_hash string|nil Hash of the file being synced
-- @param opts table|nil Sync options; see syncBook
-- @return table Array of server ids to remove, empty when there are none
function SyncService:_removedHighlightIds(client_book_id, highlights, book_file_hash, opts)
	if not self.highlight_snapshot then
		return {}
	end

	-- A diff that blew up removes nothing, which is what a book with no snapshot
	-- of its own does anyway.
	local removed = self:_bookkeeping("Failed to diff the highlight snapshot", function()
		return self.highlight_snapshot:findRemoved(client_book_id, highlights, book_file_hash)
	end)

	if not removed or #removed.ids == 0 then
		return {}
	end

	if removed.mass_removal and not self:_confirmMassRemoval(#removed.ids, opts) then
		logger.info("Crossbill SyncService: Keeping", #removed.ids, "highlights the device no longer has")
		return {}
	end

	logger.info("Crossbill SyncService: Removing", #removed.ids, "highlights deleted on this device")
	return removed.ids
end

--- Ask the reader before every highlight of a book leaves their devices
-- A book that lost its whole recorded set at once looks the same whether the
-- reader cleared it out or the file's sidecar was lost or rebuilt underneath it
-- -- which is the case ownership cannot catch, the file being its snapshot's
-- rightful owner either way. Nobody to ask -- an autosync during shutdown --
-- means the server's copy is kept.
-- @param count number How many highlights the removal would cover
-- @param opts table|nil Sync options; see syncBook
-- @return boolean True when the removal may go ahead
function SyncService:_confirmMassRemoval(count, opts)
	local confirm = opts and opts.confirm_removal
	if not confirm then
		logger.info("Crossbill SyncService: No way to confirm a mass removal, skipping it")
		return false
	end

	local ok, confirmed = pcall(confirm, count)
	if not ok then
		logger.warn("Crossbill SyncService: Removal confirmation failed:", confirmed)
		return false
	end

	return confirmed == true
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

	local book_file_hash = BookIdentity.fileHash(doc_path)

	-- Get unsynced sessions for this book only
	local sessions = self.session_tracker:getUnsyncedSessionsForBook(book_file_hash)
	if #sessions == 0 then
		logger.dbg("Crossbill SyncService: No reading sessions to sync for current book")
		return result
	end

	logger.info("Crossbill SyncService: Found", #sessions, "unsynced reading sessions")

	local code, response, err = self.api_client:uploadReadingSessions(client_book_id, sessions)
	if code == 200 and response then
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

--- Send the book's EPUB up to the server
-- The upload is unconditional, including when server_metadata.has_ebook says a
-- copy is already there: while the server's text extraction keeps changing, a
-- re-upload is what guarantees it holds a copy it can still read. That costs a
-- full EPUB over WiFi on every sync, so it is a deliberate trade to revisit
-- rather than an oversight.
--
-- Nothing here fails the sync on its own: a book the server has not heard of
-- yet, or a document that is not an EPUB, is skipped quietly, and a file that
-- cannot be read or an upload the server rejects is logged and handed back
-- without stopping anything. Only the server's refusal to serve this plugin
-- version stops the sync, and it raises out of the upload rather than arriving
-- here to be weighed.
-- @param client_book_id string The client book ID
-- @param book_metadata BookMetadata instance
-- @param server_metadata table|nil Server metadata containing has_ebook, etc.
-- @return any|nil The error the upload failed with
function SyncService:_syncFiles(client_book_id, book_metadata, server_metadata)
	if not server_metadata then
		logger.dbg("Crossbill SyncService: No server metadata, skipping EPUB upload")
		return nil
	end

	local doc_path = book_metadata:getDocPath()
	if not DocumentSupport.isEpubPath(doc_path) then
		logger.dbg("Crossbill SyncService: Document is not an EPUB file, skipping upload")
		return nil
	end

	local epub_data, read_err = self.read_file(doc_path)
	if not epub_data or epub_data == "" then
		logger.err("Crossbill SyncService: Failed to read EPUB data:", read_err)
		return read_err or "Failed to read EPUB data"
	end

	local filename = BookMetadata.getFilename(doc_path)
	logger.dbg("Crossbill SyncService: Uploading EPUB file:", filename, "size:", #epub_data, "bytes")

	local upload_code, _, upload_err = self.api_client:uploadEpub(client_book_id, epub_data, filename)
	if upload_code ~= 200 then
		logger.warn("Crossbill SyncService: EPUB upload issue:", upload_err)
		return upload_err
	end

	return nil
end

--- Fetch book metadata from the server
-- A book the server has never heard of is not an error: it is created next.
-- Everything else that went wrong is handed back for the sync to end on, since
-- a fetch that failed for another reason says nothing about whether the book is
-- there.
-- @param client_book_id string The client book ID (hash of title|author)
-- @return table|nil Server metadata containing has_ebook, etc. or nil if not found
-- @return any|nil The error the fetch failed with
function SyncService:_getServerBookMetadata(client_book_id)
	local code, metadata, err = self.api_client:getBookMetadata(client_book_id)

	if code == 404 then
		logger.dbg("Crossbill SyncService: Book not found on server")
		return nil, nil
	end

	if not metadata then
		logger.warn("Crossbill SyncService: Failed to fetch book metadata from server")
		-- Never a bare nil: that is how a book the server does not have is
		-- reported, and a failure read as one would create the book again.
		return nil, err or "Failed to fetch book metadata from server"
	end

	return metadata, nil
end

return SyncService
