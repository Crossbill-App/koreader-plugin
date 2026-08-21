local SyncService = require("modules/sync_service")
local DocSettings = require("docsettings")
local GlobalSettingsFake = require("global_settings_fake")

local CLIENT_BOOK_ID = "md5:Dune|Frank Herbert"

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
		recordPlaced = function(self, client_book_id, placed)
			if opts.throws then
				error("snapshot store blew up")
			end
			table.insert(self.calls, { client_book_id = client_book_id, placed = placed })
			return true
		end,
		findRemoved = function(self, client_book_id, highlights)
			if opts.diff_throws then
				error("snapshot store blew up")
			end
			table.insert(self.diffed, { client_book_id = client_book_id, highlights = highlights })
			return opts.removed
		end,
		flagNew = function(self, client_book_id, highlights)
			if opts.flag_throws then
				error("snapshot store blew up")
			end
			table.insert(self.flagged, { client_book_id = client_book_id, highlights = highlights })
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

			service:_applyPull({}, readerFor(), CLIENT_BOOK_ID)

			assert.are.equal(1, #ledger.calls)
			assert.are.equal(CLIENT_BOOK_ID, ledger.calls[1].client_book_id)
			assert.are.same(placed, ledger.calls[1].placed)
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
					return true,
						{
							highlights_created = #highlights,
							highlights_skipped = 0,
							highlights_removed = removed_ids and #removed_ids or 0,
						}
				end,
				getHighlights = function()
					return 200, {}
				end,
				uploadReadingSessions = function(self, _, sessions)
					self.sessions_uploaded = sessions
					return true, {}
				end,
			}
			for name, fn in pairs(overrides or {}) do
				api[name] = fn
			end
			return api
		end

		--- Build the full reader context syncBook walks through
		-- @param annotations table The in-memory annotation array
		-- @return table A stand-in for `self.ui`
		local function bookFor(annotations)
			return {
				rolling = true,
				document = { file = "/books/dune.epub" },
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
			local file_uploader = {
				uploadEpub = function()
					return true
				end,
			}
			return SyncService:new({
				api_client = api,
				file_uploader = file_uploader,
				session_tracker = opts.session_tracker,
				settings = settings,
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
				getBookFileHash = function()
					return "hash"
				end,
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
						return false, nil, "Connection refused"
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
	end)
end)
