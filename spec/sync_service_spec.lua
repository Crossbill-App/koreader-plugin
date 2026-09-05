local SyncService = require("modules/sync_service")
local AuthFailed = require("modules/auth_failed")
local HighlightSnapshot = require("modules/highlight_snapshot")
local UpgradeRequired = require("modules/upgrade_required")
local FakeSnapshotStore = require("fake_snapshot_store")
local DocSettings = require("docsettings")
local GlobalSettingsFake = require("global_settings_fake")

local CLIENT_BOOK_ID = "md5:Dune|Frank Herbert"
-- Two copies of one book: the same title and author, so the same client book
-- id, and their own sidecars behind their own file paths. The hashes are what
-- `ffi/sha2`'s stand-in makes of those paths.
local BOOK_PATH = "/books/dune.epub"
local COPY_PATH = "/books/copies/dune.epub"
local FILE_HASH = "md5:" .. BOOK_PATH
local COPY_FILE_HASH = "md5:" .. COPY_PATH

--- Build a SyncService with only the collaborators the pull touches
-- @param opts table|nil api_client, highlight_importer and highlight_snapshot overrides
-- @return table The SyncService instance
local function syncServiceWith(opts)
	opts = opts or {}
	return SyncService:new({
		api_client = opts.api_client,
		highlight_importer = opts.highlight_importer,
		highlight_snapshot = opts.highlight_snapshot,
	})
end

--- Build a snapshot ledger recording what it was asked to remember
-- @param opts table|nil throws, removed, diff_throws, new_texts and flag_throws:
--   throws Make recordPlaced blow up
--   removed The diff findRemoved answers with, nil for a book never pulled
--   diff_throws Make findRemoved blow up
--   new_texts Set of texts flagNew treats as made on this device
--   flag_throws Make flagNew blow up
-- @return table A ledger stand-in whose `calls` hold every record it took
local function ledgerRecording(opts)
	opts = opts or {}
	return {
		calls = {},
		diffed = {},
		flagged = {},
		recordPlaced = function(self, client_book_id, placed, book_file_hash)
			if opts.throws then
				error("snapshot store blew up")
			end
			table.insert(
				self.calls,
				{ client_book_id = client_book_id, placed = placed, book_file_hash = book_file_hash }
			)
			return true
		end,
		findRemoved = function(self, client_book_id, highlights, book_file_hash)
			if opts.diff_throws then
				error("snapshot store blew up")
			end
			table.insert(
				self.diffed,
				{ client_book_id = client_book_id, highlights = highlights, book_file_hash = book_file_hash }
			)
			return opts.removed
		end,
		flagNew = function(self, client_book_id, highlights, book_file_hash)
			if opts.flag_throws then
				error("snapshot store blew up")
			end
			table.insert(
				self.flagged,
				{ client_book_id = client_book_id, highlights = highlights, book_file_hash = book_file_hash }
			)
			local count = 0
			for _, highlight in ipairs(highlights) do
				if opts.new_texts and opts.new_texts[highlight.text] then
					highlight.is_new = true
					count = count + 1
				end
			end
			return count
		end,
	}
end

--- Build an api client that answers getHighlights with the given tuple
-- @param code number|nil The HTTP status
-- @param items table|nil The highlight items
-- @param err string|nil The error message
-- @return table An api client stand-in recording the ids it was asked for
local function apiReturning(code, items, err)
	return {
		asked_for = {},
		getHighlights = function(self, client_book_id)
			table.insert(self.asked_for, client_book_id)
			return code, items, err
		end,
	}
end

--- Build an importer that answers replaceHighlights with the given tuple
-- @param result table|nil The importer result
-- @param err string|nil The error message
-- @return table An importer stand-in recording the items it was handed
local function importerReturning(result, err)
	return {
		received = nil,
		calls = 0,
		replaceHighlights = function(self, _, items)
			self.calls = self.calls + 1
			self.received = items
			return result, err
		end,
	}
end

--- Build the reader context the pull reads, reflowable by default
-- @param opts table|nil rolling and annotations
-- @return table A stand-in for `self.ui`
local function readerFor(opts)
	opts = opts or {}
	return {
		rolling = opts.rolling ~= false or nil,
		annotation = opts.annotations and { annotations = opts.annotations } or nil,
	}
end

describe("SyncService", function()
	describe("_applyPull", function()
		it("records the importer's result on the sync result", function()
			local pull_result = { inserted = 3, skipped_unplaceable = 0, skipped_invalid = 0 }
			local service = syncServiceWith({
				api_client = apiReturning(200, { "one", "two" }),
				highlight_importer = importerReturning(pull_result),
			})
			local result = {}

			service:_applyPull(result, readerFor(), CLIENT_BOOK_ID)

			assert.are.equal(pull_result, result.pull)
			assert.is_nil(result.pull_error)
		end)

		it("hands the server's items to the importer", function()
			local importer = importerReturning({ inserted = 0 })
			local service = syncServiceWith({
				api_client = apiReturning(200, { "one", "two" }),
				highlight_importer = importer,
			})

			service:_applyPull({}, readerFor(), CLIENT_BOOK_ID)

			assert.are.same({ "one", "two" }, importer.received)
		end)

		it("asks the server for the book being synced", function()
			local api = apiReturning(200, {})
			local service = syncServiceWith({
				api_client = api,
				highlight_importer = importerReturning({ inserted = 0 }),
			})

			service:_applyPull({}, readerFor(), CLIENT_BOOK_ID)

			assert.are.same({ CLIENT_BOOK_ID }, api.asked_for)
		end)

		it("skips a fixed-layout book without calling the server", function()
			-- Pulled positions are xpointers, which mean nothing to a PDF. Not a
			-- failure, so there is nothing to report to the user either.
			local api = apiReturning(200, {})
			local importer = importerReturning({ inserted = 1 })
			local service = syncServiceWith({ api_client = api, highlight_importer = importer })
			local result = {}

			service:_applyPull(result, readerFor({ rolling = false }), CLIENT_BOOK_ID)

			assert.is_nil(result.pull)
			assert.is_nil(result.pull_error)
			assert.are.same({}, api.asked_for)
			assert.are.equal(0, importer.calls)
		end)

		it("reports a book the server does not know", function()
			local service = syncServiceWith({
				api_client = apiReturning(404, nil, nil),
				highlight_importer = importerReturning({ inserted = 0 }),
			})
			local result = {}

			service:_applyPull(result, readerFor(), CLIENT_BOOK_ID)

			assert.are.equal("Book not found on Crossbill", result.pull_error)
			assert.is_nil(result.pull)
		end)

		it("pulls a book the server holds no highlights for without reporting a failure", function()
			-- An empty list is an answer, not a failed fetch: the api client makes
			-- one of a 200 that carried no body, and the importer is asked to apply
			-- it, which is what clears out highlights removed elsewhere.
			local importer = importerReturning({ inserted = 0, placed = {} })
			local service = syncServiceWith({
				api_client = apiReturning(200, {}),
				highlight_importer = importer,
			})
			local result = {}

			service:_applyPull(result, readerFor(), CLIENT_BOOK_ID)

			assert.are.equal(1, importer.calls)
			assert.are.same({}, importer.received)
			assert.is_nil(result.pull_error)
		end)

		it("reports the network's error when the fetch never reached the server", function()
			local service = syncServiceWith({
				api_client = apiReturning(nil, nil, "Connection refused"),
				highlight_importer = importerReturning({ inserted = 0 }),
			})
			local result = {}

			service:_applyPull(result, readerFor(), CLIENT_BOOK_ID)

			assert.are.equal("Connection refused", result.pull_error)
		end)

		it("reports the status when the server answered with a failure", function()
			local service = syncServiceWith({
				api_client = apiReturning(500, nil, "Fetch failed: 500"),
				highlight_importer = importerReturning({ inserted = 0 }),
			})
			local result = {}

			service:_applyPull(result, readerFor(), CLIENT_BOOK_ID)

			assert.are.equal("Fetch failed: 500", result.pull_error)
		end)

		it("does not import when the fetch failed", function()
			local importer = importerReturning({ inserted = 1 })
			local service = syncServiceWith({
				api_client = apiReturning(500, nil, "Fetch failed: 500"),
				highlight_importer = importer,
			})

			service:_applyPull({}, readerFor(), CLIENT_BOOK_ID)

			assert.are.equal(0, importer.calls)
		end)

		it("reports the importer's refusal", function()
			local service = syncServiceWith({
				api_client = apiReturning(200, { "one" }),
				highlight_importer = importerReturning(nil, "Only reflowable books (EPUB) are supported"),
			})
			local result = {}

			service:_applyPull(result, readerFor(), CLIENT_BOOK_ID)

			assert.are.equal("Only reflowable books (EPUB) are supported", result.pull_error)
			assert.is_nil(result.pull)
		end)

		it("reports a bare failure the importer gave no reason for", function()
			local service = syncServiceWith({
				api_client = apiReturning(200, { "one" }),
				highlight_importer = importerReturning(nil, nil),
			})
			local result = {}

			service:_applyPull(result, readerFor(), CLIENT_BOOK_ID)

			assert.are.equal("Highlight pull failed", result.pull_error)
		end)

		it("reports a missing importer rather than throwing", function()
			local service = syncServiceWith({ api_client = apiReturning(200, {}) })
			local result = {}

			service:_applyPull(result, readerFor(), CLIENT_BOOK_ID)

			assert.are.equal("No highlight importer available", result.pull_error)
		end)

		it("survives an importer that throws", function()
			-- An autosync pulls while the book is being torn down, so a throw
			-- from deep in the reader is a real possibility.
			local service = syncServiceWith({
				api_client = apiReturning(200, { "one" }),
				highlight_importer = {
					replaceHighlights = function()
						error("annotation module blew up")
					end,
				},
			})
			local result = {}

			service:_applyPull(result, readerFor(), CLIENT_BOOK_ID)

			assert.is_truthy(result.pull_error:find("annotation module blew up", 1, true))
			assert.is_nil(result.pull)
		end)

		it("survives an api client that throws", function()
			local service = syncServiceWith({
				api_client = {
					getHighlights = function()
						error("socket closed")
					end,
				},
				highlight_importer = importerReturning({ inserted = 0 }),
			})
			local result = {}

			service:_applyPull(result, readerFor(), CLIENT_BOOK_ID)

			assert.is_truthy(result.pull_error:find("socket closed", 1, true))
		end)

		it("never fails the sync the push already completed", function()
			local service = syncServiceWith({
				api_client = apiReturning(nil, nil, "Connection refused"),
				highlight_importer = importerReturning({ inserted = 0 }),
			})
			local result = { success = true, highlights_created = 4 }

			service:_applyPull(result, readerFor(), CLIENT_BOOK_ID)

			assert.is_true(result.success)
			assert.are.equal(4, result.highlights_created)
			assert.is_nil(result.error)
		end)
	end)

	describe("the snapshot it records after a pull", function()
		local placed = { { server_id = 7, text = "the spice must flow" } }

		it("records the highlights the pull placed, for the book being synced", function()
			local ledger = ledgerRecording()
			local service = syncServiceWith({
				api_client = apiReturning(200, { "one" }),
				highlight_importer = importerReturning({ inserted = 1, placed = placed }),
				highlight_snapshot = ledger,
			})

			service:_applyPull({}, readerFor(), CLIENT_BOOK_ID, BOOK_PATH)

			assert.are.equal(1, #ledger.calls)
			assert.are.equal(CLIENT_BOOK_ID, ledger.calls[1].client_book_id)
			assert.are.same(placed, ledger.calls[1].placed)
		end)

		it("records the file the pull was applied to, which then owns the snapshot", function()
			local ledger = ledgerRecording()
			local service = syncServiceWith({
				api_client = apiReturning(200, { "one" }),
				highlight_importer = importerReturning({ inserted = 1, placed = placed }),
				highlight_snapshot = ledger,
			})

			service:_applyPull({}, readerFor(), CLIENT_BOOK_ID, BOOK_PATH)

			assert.are.equal(FILE_HASH, ledger.calls[1].book_file_hash)
		end)

		it("records a book whose file has no path, owned by no file", function()
			-- Nothing may be diffed against an unowned snapshot, but bookkeeping
			-- never stops the pull from being recorded.
			local ledger = ledgerRecording()
			local service = syncServiceWith({
				api_client = apiReturning(200, { "one" }),
				highlight_importer = importerReturning({ inserted = 1, placed = placed }),
				highlight_snapshot = ledger,
			})

			service:_applyPull({}, readerFor(), CLIENT_BOOK_ID, nil)

			assert.are.equal(1, #ledger.calls)
			assert.is_nil(ledger.calls[1].book_file_hash)
		end)

		it("records the enrolment of a book that already matched the server", function()
			local ledger = ledgerRecording()
			local service = syncServiceWith({
				api_client = apiReturning(200, { "one" }),
				highlight_importer = importerReturning({ unchanged = true, inserted = 0, placed = placed }),
				highlight_snapshot = ledger,
			})

			service:_applyPull({}, readerFor(), CLIENT_BOOK_ID)

			assert.are.same(placed, ledger.calls[1].placed)
		end)

		it("records nothing when the pull failed", function()
			-- The snapshot has to keep describing the state the device is
			-- actually in, which an aborted pull did not change.
			local ledger = ledgerRecording()
			local service = syncServiceWith({
				api_client = apiReturning(500, nil, "Fetch failed: 500"),
				highlight_importer = importerReturning({ inserted = 1, placed = placed }),
				highlight_snapshot = ledger,
			})

			service:_applyPull({}, readerFor(), CLIENT_BOOK_ID)

			assert.are.same({}, ledger.calls)
		end)

		it("records nothing when the importer refused the book", function()
			local ledger = ledgerRecording()
			local service = syncServiceWith({
				api_client = apiReturning(200, { "one" }),
				highlight_importer = importerReturning(nil, "None of the server's highlights fit this book"),
				highlight_snapshot = ledger,
			})

			service:_applyPull({}, readerFor(), CLIENT_BOOK_ID)

			assert.are.same({}, ledger.calls)
		end)

		it("records nothing for a fixed-layout book, which never pulls", function()
			local ledger = ledgerRecording()
			local service = syncServiceWith({
				api_client = apiReturning(200, { "one" }),
				highlight_importer = importerReturning({ inserted = 1, placed = placed }),
				highlight_snapshot = ledger,
			})

			service:_applyPull({}, readerFor({ rolling = false }), CLIENT_BOOK_ID)

			assert.are.same({}, ledger.calls)
		end)

		it("records nothing when the importer reported no placed set", function()
			local ledger = ledgerRecording()
			local service = syncServiceWith({
				api_client = apiReturning(200, { "one" }),
				highlight_importer = importerReturning({ inserted = 1 }),
				highlight_snapshot = ledger,
			})

			service:_applyPull({}, readerFor(), CLIENT_BOOK_ID)

			assert.are.same({}, ledger.calls)
		end)

		it("survives a ledger that throws, keeping the pull's result", function()
			-- Bookkeeping never fails a sync whose push already succeeded.
			local pull_result = { inserted = 1, placed = placed }
			local service = syncServiceWith({
				api_client = apiReturning(200, { "one" }),
				highlight_importer = importerReturning(pull_result),
				highlight_snapshot = ledgerRecording({ throws = true }),
			})
			local result = { success = true }

			service:_applyPull(result, readerFor(), CLIENT_BOOK_ID)

			assert.are.equal(pull_result, result.pull)
			assert.is_nil(result.pull_error)
			assert.is_true(result.success)
		end)
	end)

	describe("_stampNoteEdits", function()
		it("stamps the highlights whose note changed", function()
			local edited = { drawer = "lighten", note = "second thoughts", crossbill_note_seen = "first thoughts" }
			local service = syncServiceWith()

			service:_stampNoteEdits(readerFor({ annotations = { edited } }))

			assert.is_not_nil(edited.datetime_updated)
		end)

		it("leaves an unchanged note alone", function()
			local same = { drawer = "lighten", note = "remember this", crossbill_note_seen = "remember this" }
			local service = syncServiceWith()

			service:_stampNoteEdits(readerFor({ annotations = { same } }))

			assert.is_nil(same.datetime_updated)
		end)

		it("does nothing when the reader holds no annotations at all", function()
			local service = syncServiceWith()

			assert.has_no.errors(function()
				service:_stampNoteEdits(readerFor())
			end)
		end)
	end)

	describe("syncBook", function()
		local fake

		before_each(function()
			DocSettings.reset()
			fake = GlobalSettingsFake.install()
		end)

		after_each(function()
			fake.uninstall()
		end)

		--- Build the api client syncBook talks to, every call succeeding
		-- @param overrides table|nil Functions to replace
		-- @return table An api client recording what it was given
		local function apiForSyncBook(overrides)
			local api = {
				getBookMetadata = function()
					return 200, { book_id = 1 }
				end,
				uploadHighlights = function(self, _, highlights, device_id, removed_ids)
					self.uploaded = { highlights = highlights, device_id = device_id, removed_ids = removed_ids }
					return 200,
						{
							highlights_created = #highlights,
							highlights_skipped = 0,
							highlights_removed = removed_ids and #removed_ids or 0,
						}
				end,
				getHighlights = function()
					return 200, {}
				end,
				uploadEpub = function(self, _, data, filename)
					self.uploaded_epub = { data = data, filename = filename }
					return 200, {}
				end,
				uploadReadingSessions = function(self, _, sessions)
					self.sessions_uploaded = sessions
					return 200, {}
				end,
			}
			for name, fn in pairs(overrides or {}) do
				api[name] = fn
			end
			return api
		end

		--- Build the full reader context syncBook walks through
		-- @param annotations table The in-memory annotation array
		-- @param doc_path string|nil The file this copy of the book lives in
		-- @return table A stand-in for `self.ui`
		local function bookFor(annotations, doc_path)
			return {
				rolling = true,
				document = { file = doc_path or BOOK_PATH },
				doc_props = { title = "Dune", authors = "Frank Herbert" },
				annotation = { annotations = annotations },
			}
		end

		local function serviceFor(api, opts)
			opts = opts or {}
			local settings = {
				isSessionTrackingEnabled = function()
					return opts.session_tracker ~= nil
				end,
			}
			return SyncService:new({
				api_client = api,
				read_file = opts.read_file or function()
					return "epub-bytes"
				end,
				session_tracker = opts.session_tracker,
				settings = settings,
				digest_service = opts.digest_service,
				highlight_importer = opts.highlight_importer,
				highlight_snapshot = opts.highlight_snapshot,
			})
		end

		it("stamps an edited note before the highlights are extracted", function()
			local api = apiForSyncBook()
			local edited = {
				drawer = "lighten",
				pos0 = "/body/DocFragment[3]/p[1]/text()[0]",
				pos1 = "/body/DocFragment[3]/p[1]/text()[9]",
				text = "a passage",
				note = "edited on the device",
				crossbill_note_seen = "what the server holds",
				datetime = "2024-01-01 10:00:00",
			}
			local service = serviceFor(api, { highlight_importer = importerReturning({ inserted = 0 }) })

			service:syncBook(bookFor({ edited }))

			assert.are.equal(1, #api.uploaded.highlights)
			assert.is_string(api.uploaded.highlights[1].datetime_updated)
		end)

		it("sends the device id with the highlights", function()
			local api = apiForSyncBook()
			local service = serviceFor(api, { highlight_importer = importerReturning({ inserted = 0 }) })

			service:syncBook(bookFor({ { drawer = "lighten", text = "a passage" } }))

			assert.is_string(api.uploaded.device_id)
			assert.is_not.equal("", api.uploaded.device_id)
		end)

		it("still uploads reading sessions when the pull failed", function()
			local api = apiForSyncBook({
				getHighlights = function()
					return 500, nil, "server exploded"
				end,
			})
			local session_tracker = {
				getUnsyncedSessionsForBook = function()
					return { { id = 7 } }
				end,
				markSessionsSynced = function(self, ids)
					self.marked = ids
				end,
			}
			local service = serviceFor(api, { session_tracker = session_tracker })

			local result = service:syncBook(bookFor({ { drawer = "lighten", text = "a passage" } }))

			assert.is_truthy(result.pull_error)
			assert.are.equal(1, result.sessions_synced)
			assert.are.same({ 7 }, session_tracker.marked)
		end)

		describe("the EPUB it sends up with the book", function()
			local A_HIGHLIGHT = { drawer = "lighten", text = "a passage" }

			it("uploads the file under its own name", function()
				local api = apiForSyncBook()
				local service = serviceFor(api, {})

				service:syncBook(bookFor({ A_HIGHLIGHT }))

				assert.are.same({ data = "epub-bytes", filename = "dune.epub" }, api.uploaded_epub)
			end)

			it("uploads a book whose extension is upper case", function()
				-- A reader's library is full of Book.EPUB, and a case-sensitive
				-- check used to sync its highlights while never sending the file.
				local api = apiForSyncBook()
				local service = serviceFor(api, {})

				service:syncBook(bookFor({ A_HIGHLIGHT }, "/books/DUNE.EPUB"))

				assert.are.same({ data = "epub-bytes", filename = "DUNE.EPUB" }, api.uploaded_epub)
			end)

			it("skips a document that is not an EPUB", function()
				local api = apiForSyncBook()
				local service = serviceFor(api, {})

				local result = service:syncBook(bookFor({ A_HIGHLIGHT }, "/books/dune.pdf"))

				assert.is_nil(api.uploaded_epub)
				assert.is_true(result.success)
			end)

			it("ends the sync when the created book came back with no metadata", function()
				-- Without the book the server made there is nothing to upload the
				-- EPUB against, and a sync that quietly sends no file is worse than
				-- one that says what it could not do.
				local api = apiForSyncBook({
					getBookMetadata = function()
						return 404
					end,
					createBook = function()
						-- Created, but with nothing said back about the book.
						return 200, nil
					end,
				})
				local service = serviceFor(api, {})

				local result = service:syncBook(bookFor({ A_HIGHLIGHT }))

				assert.is_false(result.success)
				assert.are.equal("Create book failed: the server sent no book back", result.error)
				assert.is_nil(api.uploaded_epub)
			end)

			it("carries on with the sync when the file cannot be read", function()
				local api = apiForSyncBook()
				local service = serviceFor(api, {
					read_file = function()
						return nil, "No such file"
					end,
				})

				local result = service:syncBook(bookFor({ A_HIGHLIGHT }))

				assert.is_nil(api.uploaded_epub)
				assert.is_true(result.success)
				assert.are.equal(1, #api.uploaded.highlights)
			end)

			it("carries on with the sync when the file is empty", function()
				local api = apiForSyncBook()
				local service = serviceFor(api, {
					read_file = function()
						return ""
					end,
				})

				local result = service:syncBook(bookFor({ A_HIGHLIGHT }))

				assert.is_nil(api.uploaded_epub)
				assert.is_true(result.success)
			end)

			it("hands back the upload's own error without failing the sync", function()
				local api = apiForSyncBook({
					uploadEpub = function()
						return 500, nil, "server exploded"
					end,
				})
				local service = serviceFor(api, {})
				local book_metadata = {
					getDocPath = function()
						return BOOK_PATH
					end,
				}

				local err = service:_syncFiles(CLIENT_BOOK_ID, book_metadata, { book_id = 1 })
				local result = service:syncBook(bookFor({ A_HIGHLIGHT }))

				assert.are.equal("server exploded", err)
				assert.is_true(result.success)
				assert.are.equal(1, #api.uploaded.highlights)
			end)
		end)

		describe("the removals it sends with the push", function()
			local A_HIGHLIGHT = { drawer = "lighten", text = "a passage" }

			--- Sync a book whose ledger answers with the given diff
			-- @param api table The api client stand-in
			-- @param removed table|nil What findRemoved answers
			-- @param opts table|nil confirm_removal and annotations
			-- @return table The sync result
			-- @return table The ledger stand-in
			local function syncWithDiff(api, removed, opts)
				opts = opts or {}
				local ledger = ledgerRecording({ removed = removed })
				local service = serviceFor(api, {
					highlight_importer = importerReturning({ inserted = 0 }),
					highlight_snapshot = ledger,
				})
				local result = service:syncBook(
					bookFor(opts.annotations or { A_HIGHLIGHT }),
					{ confirm_removal = opts.confirm_removal }
				)
				return result, ledger
			end

			it("sends the ids of the highlights deleted on the device", function()
				local api = apiForSyncBook()

				syncWithDiff(api, { ids = { 7, 12 }, mass_removal = false })

				assert.are.same({ 7, 12 }, api.uploaded.removed_ids)
			end)

			it("diffs the extracted highlights against the book being synced", function()
				local _, ledger = syncWithDiff(apiForSyncBook(), { ids = {}, mass_removal = false })

				assert.are.equal(1, #ledger.diffed)
				assert.are.equal(CLIENT_BOOK_ID, ledger.diffed[1].client_book_id)
				assert.are.equal("a passage", ledger.diffed[1].highlights[1].text)
			end)

			it("names the file being synced, so only its own snapshot is diffed", function()
				local _, ledger = syncWithDiff(apiForSyncBook(), { ids = {}, mass_removal = false })

				assert.are.equal(FILE_HASH, ledger.diffed[1].book_file_hash)
			end)

			it("sends no removals for a book that has never pulled", function()
				local api = apiForSyncBook()

				syncWithDiff(api, nil)

				assert.are.same({}, api.uploaded.removed_ids)
			end)

			it("reports how many the server withdrew", function()
				local result = syncWithDiff(apiForSyncBook(), { ids = { 7, 12 }, mass_removal = false })

				assert.are.equal(2, result.highlights_removed)
			end)

			it("pushes removals even when the book has no highlights left", function()
				-- The upload is the only channel removals travel on, so a book
				-- emptied on the device still has something to say.
				local api = apiForSyncBook()

				syncWithDiff(api, { ids = { 7 }, mass_removal = false }, { annotations = {} })

				assert.are.same({ 7 }, api.uploaded.removed_ids)
				assert.are.same({}, api.uploaded.highlights)
			end)

			it("does not reach the server when there is nothing to push at all", function()
				local api = apiForSyncBook()

				syncWithDiff(api, { ids = {}, mass_removal = false }, { annotations = {} })

				assert.is_nil(api.uploaded)
			end)

			it("asks before removing every highlight the book had", function()
				local asked = {}
				syncWithDiff(apiForSyncBook(), { ids = { 7, 12 }, mass_removal = true }, {
					annotations = {},
					confirm_removal = function(count)
						table.insert(asked, count)
						return true
					end,
				})

				assert.are.same({ 2 }, asked)
			end)

			it("sends the removals the reader confirmed", function()
				local api = apiForSyncBook()

				syncWithDiff(api, { ids = { 7, 12 }, mass_removal = true }, {
					annotations = {},
					confirm_removal = function()
						return true
					end,
				})

				assert.are.same({ 7, 12 }, api.uploaded.removed_ids)
			end)

			it("keeps the server's copy when the reader declines", function()
				local api = apiForSyncBook()

				local result = syncWithDiff(api, { ids = { 7, 12 }, mass_removal = true }, {
					confirm_removal = function()
						return false
					end,
				})

				assert.are.same({}, api.uploaded.removed_ids)
				assert.is_true(result.success)
				assert.are.equal(0, result.highlights_removed)
			end)

			it("keeps the server's copy when there is nobody to ask", function()
				-- An autosync during shutdown has no reader in front of it, and
				-- a lost sidecar must not empty the account unattended.
				local api = apiForSyncBook()

				syncWithDiff(api, { ids = { 7, 12 }, mass_removal = true })

				assert.are.same({}, api.uploaded.removed_ids)
			end)

			it("keeps the server's copy when the question itself failed", function()
				local api = apiForSyncBook()

				syncWithDiff(api, { ids = { 7 }, mass_removal = true }, {
					confirm_removal = function()
						error("no widget to show")
					end,
				})

				assert.are.same({}, api.uploaded.removed_ids)
			end)

			it("asks nothing for an ordinary removal", function()
				local asked = 0
				local api = apiForSyncBook()

				syncWithDiff(api, { ids = { 7 }, mass_removal = false }, {
					confirm_removal = function()
						asked = asked + 1
						return false
					end,
				})

				assert.are.equal(0, asked)
				assert.are.same({ 7 }, api.uploaded.removed_ids)
			end)

			it("still pushes the highlights when the ledger throws", function()
				local api = apiForSyncBook()
				local service = serviceFor(api, {
					highlight_importer = importerReturning({ inserted = 0 }),
					highlight_snapshot = ledgerRecording({ diff_throws = true }),
				})

				local result = service:syncBook(bookFor({ A_HIGHLIGHT }))

				assert.is_true(result.success)
				assert.are.equal(1, #api.uploaded.highlights)
				assert.are.same({}, api.uploaded.removed_ids)
			end)

			it("fails the sync when the upload carrying the removals failed", function()
				-- The snapshot only moves on after a successful pull, so the
				-- next sync diffs the same removals out again.
				local api = apiForSyncBook({
					uploadHighlights = function()
						return nil, nil, "Connection refused"
					end,
				})

				local result = syncWithDiff(api, { ids = { 7 }, mass_removal = false })

				assert.is_false(result.success)
				assert.are.equal("Connection refused", result.error)
			end)
		end)

		describe("the highlights it flags as new on this device", function()
			local A_PASSAGE = { drawer = "lighten", text = "a passage" }
			local ANOTHER_PASSAGE = { drawer = "lighten", text = "another passage" }

			--- Sync a book whose ledger calls the given texts new
			-- @param api table The api client stand-in
			-- @param opts table|nil new_texts, flag_throws and annotations
			-- @return table The sync result
			-- @return table The ledger stand-in
			local function syncWithFlagging(api, opts)
				opts = opts or {}
				local ledger = ledgerRecording({
					new_texts = opts.new_texts,
					flag_throws = opts.flag_throws,
				})
				local service = serviceFor(api, {
					highlight_importer = importerReturning({ inserted = 0 }),
					highlight_snapshot = ledger,
				})
				local result = service:syncBook(bookFor(opts.annotations or { A_PASSAGE, ANOTHER_PASSAGE }))
				return result, ledger
			end

			it("marks a highlight the ledger has never pulled", function()
				local api = apiForSyncBook()

				syncWithFlagging(api, { new_texts = { ["another passage"] = true } })

				assert.is_nil(api.uploaded.highlights[1].is_new)
				assert.is_true(api.uploaded.highlights[2].is_new)
			end)

			it("flags the extracted highlights of the book being synced", function()
				local _, ledger = syncWithFlagging(apiForSyncBook())

				assert.are.equal(1, #ledger.flagged)
				assert.are.equal(CLIENT_BOOK_ID, ledger.flagged[1].client_book_id)
				assert.are.equal("a passage", ledger.flagged[1].highlights[1].text)
			end)

			it("names the file being synced, so only its own snapshot flags", function()
				local _, ledger = syncWithFlagging(apiForSyncBook())

				assert.are.equal(FILE_HASH, ledger.flagged[1].book_file_hash)
			end)

			it("marks nothing when every pushed highlight came from the server", function()
				local api = apiForSyncBook()

				syncWithFlagging(api)

				assert.is_nil(api.uploaded.highlights[1].is_new)
				assert.is_nil(api.uploaded.highlights[2].is_new)
			end)

			it("still pushes the highlights when the ledger throws", function()
				-- Unflagged highlights are the behaviour that shipped before
				-- the flag existed, which beats a sync lost to bookkeeping.
				local api = apiForSyncBook()

				local result = syncWithFlagging(api, { flag_throws = true })

				assert.is_true(result.success)
				assert.are.equal(2, #api.uploaded.highlights)
				assert.is_nil(api.uploaded.highlights[1].is_new)
			end)

			it("pushes unflagged highlights when there is no ledger at all", function()
				local api = apiForSyncBook()
				local service = serviceFor(api, { highlight_importer = importerReturning({ inserted = 0 }) })

				local result = service:syncBook(bookFor({ A_PASSAGE }))

				assert.is_true(result.success)
				assert.is_nil(api.uploaded.highlights[1].is_new)
			end)
		end)

		describe("a second copy of a book another file has already pulled", function()
			-- #609: both copies share the ledger key, so before ownership the
			-- second copy diffed the first one's snapshot and reported its
			-- highlights as deletions made here. Alternating syncs between the
			-- copies then withheld every highlight of the book from every
			-- device. The real ledger and its store stand in for the stubs here,
			-- because ownership is the thing under test.
			local THE_OTHER_COPYS_HIGHLIGHT = "a passage the other copy holds"
			local ITS_OWN_HIGHLIGHT = { drawer = "lighten", text = "a passage only this copy holds" }

			--- Build a ledger the book's first copy has already recorded into
			-- @return table The ledger, backed by the in-memory store
			local function ledgerOwnedByTheFirstCopy()
				local ledger = HighlightSnapshot:new({ store = FakeSnapshotStore:new() })
				ledger:init()
				ledger:recordPlaced(CLIENT_BOOK_ID, { { server_id = 7, text = THE_OTHER_COPYS_HIGHLIGHT } }, FILE_HASH)
				return ledger
			end

			--- Build the service the second copy syncs through
			-- Its pull places the server's one highlight, as the first copy's did.
			-- @param api table The api client stand-in
			-- @param ledger table The ledger both copies share
			-- @return table The SyncService instance
			local function serviceForTheCopy(api, ledger)
				return serviceFor(api, {
					highlight_importer = importerReturning({
						inserted = 1,
						placed = { { server_id = 7, text = THE_OTHER_COPYS_HIGHLIGHT } },
					}),
					highlight_snapshot = ledger,
				})
			end

			it("removes nothing and asks nothing until it has pulled for itself", function()
				local api = apiForSyncBook()
				local asked = 0
				local service = serviceForTheCopy(api, ledgerOwnedByTheFirstCopy())

				local result = service:syncBook(bookFor({ ITS_OWN_HIGHLIGHT }, COPY_PATH), {
					confirm_removal = function()
						asked = asked + 1
						return true
					end,
				})

				assert.is_true(result.success)
				assert.are.same({}, api.uploaded.removed_ids)
				assert.are.equal(0, asked)
			end)

			it("flags nothing of its own against the other copy's snapshot", function()
				-- Flagged, its stale highlights would ask the server to revive
				-- whatever the reader deleted on the web.
				local api = apiForSyncBook()
				local service = serviceForTheCopy(api, ledgerOwnedByTheFirstCopy())

				service:syncBook(bookFor({ ITS_OWN_HIGHLIGHT }, COPY_PATH))

				assert.is_nil(api.uploaded.highlights[1].is_new)
			end)

			it("owns the ledger after its own pull and diffs normally from then on", function()
				local api = apiForSyncBook()
				local ledger = ledgerOwnedByTheFirstCopy()
				local service = serviceForTheCopy(api, ledger)
				local asked = {}
				local opts = {
					confirm_removal = function(count)
						table.insert(asked, count)
						return true
					end,
				}

				service:syncBook(bookFor({ ITS_OWN_HIGHLIGHT }, COPY_PATH), opts)

				assert.are.equal(COPY_FILE_HASH, ledger:getBookFileHash(CLIENT_BOOK_ID))

				-- The reader now deletes the pulled highlight in this copy.
				service:syncBook(bookFor({}, COPY_PATH), opts)

				assert.are.same({ 7 }, api.uploaded.removed_ids)
				assert.are.same({ 1 }, asked)
			end)

			it("leaves the server's set intact when the two copies sync in turn", function()
				-- The convergence #609 reports: each copy diffed the snapshot the
				-- other had just written and read the other's highlights as
				-- deletions made here, so alternating syncs stripped the book from
				-- every device. Whichever copy syncs next never owns the snapshot
				-- the other one left, so it never sends a removal. Deletion made
				-- on either copy is deferred while both stay active, which is the
				-- safe direction.
				local api = apiForSyncBook()
				local service = serviceForTheCopy(api, ledgerOwnedByTheFirstCopy())
				local asked = 0
				local opts = {
					-- A confirmation that says yes, so a removal the diff wrongly
					-- found would reach the server rather than be skipped here.
					confirm_removal = function()
						asked = asked + 1
						return true
					end,
				}
				local copies = {
					{ path = COPY_PATH, holds = { ITS_OWN_HIGHLIGHT } },
					{ path = BOOK_PATH, holds = { { drawer = "lighten", text = THE_OTHER_COPYS_HIGHLIGHT } } },
				}
				local removed_per_sync = {}

				for i = 1, 4 do
					local copy = copies[(i - 1) % 2 + 1]
					service:syncBook(bookFor(copy.holds, copy.path), opts)
					table.insert(removed_per_sync, #api.uploaded.removed_ids)
				end

				assert.are.same({ 0, 0, 0, 0 }, removed_per_sync)
				assert.are.equal(0, asked)
			end)
		end)
		describe("a reader the server would not authenticate", function()
			it("ends the sync with the failure still recognisable as one", function()
				-- main.lua picks the dialog by the error's type, so the sync must
				-- carry it through rather than flatten it into its own wording.
				local refused = AuthFailed.new("Login failed: 401")
				local api = apiForSyncBook({
					getBookMetadata = function()
						return nil, nil, refused
					end,
					createBook = function(self)
						self.created = true
						return 200, {}
					end,
				})
				local service = serviceFor(api, {})

				local result = service:syncBook(bookFor({ { drawer = "lighten", text = "a passage" } }))

				assert.is_false(result.success)
				assert.is_true(AuthFailed.is(result.error))
				assert.are.equal("Login failed: 401", AuthFailed.message(result.error))
				-- And the book is not created blind on the way: a fetch that
				-- failed on the reader's credentials says nothing about whether
				-- the server has the book.
				assert.is_nil(api.created)
			end)

			it("ends the sync on any other failed metadata fetch too", function()
				-- Only a 404 means "no such book"; anything else that goes wrong
				-- would meet the same failure again a step later, and report it
				-- from further away.
				local api = apiForSyncBook({
					getBookMetadata = function()
						return 500, nil, "Fetch failed: 500"
					end,
					createBook = function(self)
						self.created = true
						return 200, {}
					end,
				})
				local service = serviceFor(api, {})

				local result = service:syncBook(bookFor({ { drawer = "lighten", text = "a passage" } }))

				assert.is_false(result.success)
				assert.are.equal("Fetch failed: 500", result.error)
				assert.is_nil(api.created)
			end)
		end)

		describe("a metadata fetch the server answered with no book", function()
			it("ends the sync saying so, rather than creating the book again", function()
				-- A 200 with no body is a successful call that told the sync
				-- nothing, and only a 404 means the server does not have the book.
				local api = apiForSyncBook({
					getBookMetadata = function()
						return 200, nil
					end,
					createBook = function(self)
						self.created = true
						return 200, {}
					end,
				})
				local service = serviceFor(api, {})

				local result = service:syncBook(bookFor({ { drawer = "lighten", text = "a passage" } }))

				assert.is_false(result.success)
				assert.are.equal("The server sent no book metadata back", result.error)
				assert.is_nil(api.created)
			end)
		end)

		describe("a server that turns this plugin away as too old", function()
			local A_HIGHLIGHT = { drawer = "lighten", text = "a passage" }
			local REFUSAL = UpgradeRequired.fromResponse(426, {
				detail = {
					code = "client_upgrade_required",
					client = "koreader-plugin",
					min_supported_version = "0.13.0",
					received_version = "0.12.0",
					update_url = "https://github.com/Crossbill-App/koreader-plugin",
				},
			})

			-- The refusals the sync handed on, and the options that ask to hear
			-- about them.
			local told
			local telling

			before_each(function()
				told = {}
				telling = {
					on_upgrade_required = function(err)
						table.insert(told, err)
					end,
				}
			end)

			--- Build an api client the server refuses every call of
			-- Refused the way the real client refuses: by raising, so a step that
			-- says nothing about the refusal cannot swallow it.
			-- @return table The api client, recording the calls it took
			local function apiRefusingEverything()
				local function refuse(api, name)
					table.insert(api.calls, name)
					error(REFUSAL, 0)
				end
				local api = { calls = {} }
				api.getBookMetadata = function(self)
					return refuse(self, "getBookMetadata")
				end
				api.createBook = function(self)
					return refuse(self, "createBook")
				end
				api.uploadHighlights = function(self)
					return refuse(self, "uploadHighlights")
				end
				api.getHighlights = function(self)
					return refuse(self, "getHighlights")
				end
				api.uploadReadingSessions = function(self)
					return refuse(self, "uploadReadingSessions")
				end
				return api
			end

			it("gives up at the first refusal instead of collecting it again", function()
				local api = apiRefusingEverything()
				local service = serviceFor(api, { highlight_importer = importerReturning({ inserted = 0 }) })

				local result = service:syncBook(bookFor({ A_HIGHLIGHT }), telling)

				assert.are.same({ "getBookMetadata" }, api.calls)
				assert.is_false(result.success)
				assert.is_true(UpgradeRequired.is(result.upgrade_required))
			end)

			it("hands the refusal on once for the whole sync attempt", function()
				local api = apiRefusingEverything()
				local service = serviceFor(api, { highlight_importer = importerReturning({ inserted = 0 }) })

				service:syncBook(bookFor({ A_HIGHLIGHT }), telling)

				assert.are.same({ REFUSAL }, told)
			end)

			it("hands on the refusal itself, so the words are the caller's to choose", function()
				-- The message is composed from the versions the server named,
				-- which is why the refusal travels rather than a string.
				local service = serviceFor(apiRefusingEverything(), {})

				service:syncBook(bookFor({ A_HIGHLIGHT }), telling)

				assert.are.equal("0.12.0", told[1].received_version)
				assert.are.equal("0.13.0", told[1].min_supported_version)
			end)

			it("stops just the same when there is nobody to tell", function()
				-- A caller with no screen gets the refusal in the result instead.
				local api = apiRefusingEverything()
				local service = serviceFor(api, {})

				local result = service:syncBook(bookFor({ A_HIGHLIGHT }))

				assert.are.same({ "getBookMetadata" }, api.calls)
				assert.are.equal(REFUSAL, result.upgrade_required)
			end)

			it("finishes the abort even when telling the reader blows up", function()
				local service = serviceFor(apiRefusingEverything(), {})

				local result = service:syncBook(bookFor({ A_HIGHLIGHT }), {
					on_upgrade_required = function()
						error("no screen to show it on")
					end,
				})

				assert.is_false(result.success)
				assert.are.equal(REFUSAL, result.upgrade_required)
			end)

			it("reports the refusal as a message the caller can still read", function()
				-- The plugin's callers treat a sync error as a string, and one of
				-- them matches on it.
				local service = serviceFor(apiRefusingEverything(), {})

				local result = service:syncBook(bookFor({ A_HIGHLIGHT }), telling)

				assert.is_string(result.error)
				assert.is_truthy(result.error:match("^Your Crossbill plugin"))
			end)

			it("stops before the pull and the sessions when the push is refused", function()
				-- Nothing half-done: the sync that follows an update carries the
				-- removals and the sessions alike.
				local api = apiForSyncBook({
					uploadHighlights = function()
						error(REFUSAL, 0)
					end,
					getHighlights = function(self)
						self.pulled = true
						return 200, {}
					end,
					uploadReadingSessions = function(self)
						self.sessions_uploaded = true
						return 200, {}
					end,
				})
				local session_tracker = {
					getUnsyncedSessionsForBook = function()
						return { { id = 7 } }
					end,
					markSessionsSynced = function(self, ids)
						self.marked = ids
					end,
				}
				local service = serviceFor(api, {
					session_tracker = session_tracker,
					highlight_importer = importerReturning({ inserted = 0 }),
				})

				local result = service:syncBook(bookFor({ A_HIGHLIGHT }), telling)

				assert.is_false(result.success)
				assert.is_nil(api.pulled)
				assert.is_nil(api.sessions_uploaded)
				assert.is_nil(session_tracker.marked)
				assert.are.same({ REFUSAL }, told)
			end)

			it("stops when the EPUB upload is the call that is refused", function()
				-- An EPUB upload that fails is otherwise only logged, but a refusal
				-- is about the plugin rather than about the file.
				local api = apiForSyncBook({
					uploadEpub = function()
						error(REFUSAL, 0)
					end,
					uploadHighlights = function(self)
						self.pushed = true
						return 200, {}
					end,
				})
				local service = serviceFor(api, {})

				local result = service:syncBook(bookFor({ A_HIGHLIGHT }), telling)

				assert.is_false(result.success)
				assert.is_nil(api.pushed)
				assert.are.same({ REFUSAL }, told)
			end)

			it("stops when creating the book is the first call to be refused", function()
				-- A new book makes the metadata fetch a 404 rather than a refusal,
				-- so the create is where a first sync meets it.
				local api = apiForSyncBook({
					getBookMetadata = function()
						return 404
					end,
					createBook = function()
						error(REFUSAL, 0)
					end,
					uploadHighlights = function(self)
						self.pushed = true
						return 200, {}
					end,
				})
				local service = serviceFor(api, {})

				local result = service:syncBook(bookFor({ A_HIGHLIGHT }), telling)

				assert.is_false(result.success)
				assert.are.equal(REFUSAL, result.upgrade_required)
				assert.is_nil(api.pushed)
				assert.are.same({ REFUSAL }, told)
			end)

			it("stops when the digest refresh at the end is the call that is refused", function()
				-- The sync is over bar the bookkeeping by then, and bookkeeping
				-- that blows up is otherwise swallowed -- but a refused refresh
				-- still means the reader has to update.
				local api = apiForSyncBook()
				local service = serviceFor(api, {
					highlight_importer = importerReturning({ inserted = 0 }),
					digest_service = {
						refreshBook = function()
							error(REFUSAL, 0)
						end,
					},
				})

				local result = service:syncBook(bookFor({ A_HIGHLIGHT }), telling)

				assert.is_false(result.success)
				assert.are.equal(REFUSAL, result.upgrade_required)
				assert.are.same({ REFUSAL }, told)
			end)

			it("stops when the refusal only comes back from the pull", function()
				-- The pull is bookkeeping too, and swallows what it catches; the
				-- refusal is what it has to hand on instead.
				local api = apiForSyncBook({
					getHighlights = function()
						error(REFUSAL, 0)
					end,
					uploadReadingSessions = function(self)
						self.sessions_uploaded = true
						return 200, {}
					end,
				})
				local service = serviceFor(api, {
					highlight_importer = importerReturning({ inserted = 0 }),
					session_tracker = {
						getUnsyncedSessionsForBook = function()
							return { { id = 7 } }
						end,
						markSessionsSynced = function() end,
					},
				})

				local result = service:syncBook(bookFor({ A_HIGHLIGHT }), telling)

				assert.is_false(result.success)
				assert.is_nil(api.sessions_uploaded)
				assert.are.same({ REFUSAL }, told)
			end)

			it("leaves an ordinary failure to the sync's usual reporting", function()
				-- Only a refusal ends a sync early and is handed on to be shown.
				local api = apiForSyncBook({
					getHighlights = function()
						return 500, nil, "server exploded"
					end,
				})
				local service = serviceFor(api, {})

				local result = service:syncBook(bookFor({ A_HIGHLIGHT }), telling)

				assert.is_true(result.success)
				assert.is_nil(result.upgrade_required)
				assert.are.same({}, told)
			end)

			it("still swallows a bookkeeping failure that is not the refusal", function()
				-- The whole of the rule: bookkeeping never fails a sync, except
				-- the server's refusal, which ends it.
				local api = apiForSyncBook()
				local service = serviceFor(api, {
					highlight_importer = importerReturning({
						inserted = 1,
						placed = { { server_id = 1, text = A_HIGHLIGHT.text } },
					}),
					highlight_snapshot = ledgerRecording({ throws = true }),
				})

				local result = service:syncBook(bookFor({ A_HIGHLIGHT }), telling)

				assert.is_true(result.success)
				assert.is_nil(result.upgrade_required)
				assert.are.same({}, told)
			end)

			it("lets an error that is not the refusal out of the sync as it was", function()
				-- main.lua wraps the sync in a pcall of its own, and the one catch
				-- this service keeps must not stand in for that one.
				local api = apiForSyncBook({
					uploadHighlights = function()
						error("socket closed", 0)
					end,
				})
				local service = serviceFor(api, {})

				local ok, err = pcall(function()
					return service:syncBook(bookFor({ A_HIGHLIGHT }), telling)
				end)

				assert.is_false(ok)
				assert.are.equal("socket closed", err)
				assert.are.same({}, told)
			end)
		end)
	end)
end)
