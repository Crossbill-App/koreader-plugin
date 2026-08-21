local HighlightSnapshot = require("modules/highlight_snapshot")
local FakeSnapshotStore = require("fake_snapshot_store")

local CLIENT_BOOK_ID = "md5:Dune|Frank Herbert"

-- Nullable JSON fields decode to a sentinel rather than to nil, so the ledger
-- has to treat anything that is not a string as absent.
local JSON_NULL = setmetatable({}, {
	__tostring = function()
		return "null"
	end,
})

--- Build a ledger over a fake store, opened unless the test says otherwise
-- @param opts table|nil store and init
-- @return table The ledger
-- @return table The store behind it
local function ledgerWith(opts)
	opts = opts or {}
	local store = opts.store or FakeSnapshotStore:new()
	local snapshot = HighlightSnapshot:new({ store = store })
	if opts.init ~= false then
		snapshot:init("/settings")
	end
	return snapshot, store
end

describe("HighlightSnapshot", function()
	describe("hashText", function()
		it("hashes the text the server hashed", function()
			-- The server's dedup identity is sha256 of the highlight's text with
			-- no normalisation, so the device has to hash it verbatim.
			assert.are.equal(
				"sha256:A beginning is the time for taking care",
				HighlightSnapshot.hashText("A beginning is the time for taking care")
			)
		end)

		it("refuses an empty text", function()
			assert.is_nil(HighlightSnapshot.hashText(""))
		end)

		it("refuses a value that is not a string", function()
			assert.is_nil(HighlightSnapshot.hashText(JSON_NULL))
			assert.is_nil(HighlightSnapshot.hashText(nil))
		end)
	end)

	describe("init", function()
		it("opens the store in the given data directory", function()
			local _, store = ledgerWith()

			assert.are.equal("/settings", store.opened_with)
		end)

		it("reports a store that could not open", function()
			local store = FakeSnapshotStore:new()
			store.fails_at = "open"
			local snapshot = HighlightSnapshot:new({ store = store })

			assert.is_false(snapshot:init("/settings"))
		end)
	end)

	describe("recordPlaced", function()
		it("stores each highlight's server id against the hash of its text", function()
			local snapshot, store = ledgerWith()

			snapshot:recordPlaced(CLIENT_BOOK_ID, {
				{ server_id = 7, text = "Fear is the mind-killer" },
				{ server_id = 12, text = "The spice must flow" },
			})

			assert.are.same({
				{ server_id = 7, text_hash = "sha256:Fear is the mind-killer" },
				{ server_id = 12, text_hash = "sha256:The spice must flow" },
			}, store:getBook(CLIENT_BOOK_ID))
		end)

		it("replaces the book's previous rows rather than merging", function()
			-- The snapshot mirrors the server, and the server is the master: a
			-- highlight the pull no longer carries is gone, not still there.
			local snapshot, store = ledgerWith()

			snapshot:recordPlaced(CLIENT_BOOK_ID, { { server_id = 7, text = "Fear is the mind-killer" } })
			snapshot:recordPlaced(CLIENT_BOOK_ID, { { server_id = 12, text = "The spice must flow" } })

			assert.are.same({
				{ server_id = 12, text_hash = "sha256:The spice must flow" },
			}, store:getBook(CLIENT_BOOK_ID))
		end)

		it("leaves other books alone", function()
			local snapshot, store = ledgerWith()

			snapshot:recordPlaced(CLIENT_BOOK_ID, { { server_id = 7, text = "Fear is the mind-killer" } })
			snapshot:recordPlaced("md5:Emma|Jane Austen", { { server_id = 30, text = "Handsome, clever, and rich" } })

			assert.are.same({
				{ server_id = 7, text_hash = "sha256:Fear is the mind-killer" },
			}, store:getBook(CLIENT_BOOK_ID))
		end)

		it("enrols a book whose pull placed nothing", function()
			-- A pull that legitimately returned no highlights is still a
			-- successful pull, and the book has to become diffable.
			local snapshot, store = ledgerWith()

			assert.is_true(snapshot:recordPlaced(CLIENT_BOOK_ID, {}))

			assert.is_true(store:hasBook(CLIENT_BOOK_ID))
			assert.are.same({}, store:getBook(CLIENT_BOOK_ID))
		end)

		it("keeps one row per server id when two highlights share their text", function()
			local snapshot, store = ledgerWith()

			snapshot:recordPlaced(CLIENT_BOOK_ID, {
				{ server_id = 7, text = "Fear is the mind-killer" },
				{ server_id = 8, text = "Fear is the mind-killer" },
			})

			assert.are.same({
				{ server_id = 7, text_hash = "sha256:Fear is the mind-killer" },
				{ server_id = 8, text_hash = "sha256:Fear is the mind-killer" },
			}, store:getBook(CLIENT_BOOK_ID))
		end)

		it("drops a highlight whose server id is not a whole number", function()
			local snapshot, store = ledgerWith()

			snapshot:recordPlaced(CLIENT_BOOK_ID, {
				{ server_id = 1.5, text = "Fear is the mind-killer" },
				{ server_id = "12", text = "The spice must flow" },
				{ text = "Without id" },
				{ server_id = 12, text = "The spice must flow" },
			})

			assert.are.same({
				{ server_id = 12, text_hash = "sha256:The spice must flow" },
			}, store:getBook(CLIENT_BOOK_ID))
		end)

		it("drops a highlight without usable text", function()
			local snapshot, store = ledgerWith()

			snapshot:recordPlaced(CLIENT_BOOK_ID, {
				{ server_id = 7, text = "" },
				{ server_id = 8, text = JSON_NULL },
				{ server_id = 12, text = "The spice must flow" },
			})

			assert.are.same({
				{ server_id = 12, text_hash = "sha256:The spice must flow" },
			}, store:getBook(CLIENT_BOOK_ID))
		end)

		it("refuses to record before the ledger was opened", function()
			local snapshot, store = ledgerWith({ init = false })

			assert.is_false(snapshot:recordPlaced(CLIENT_BOOK_ID, { { server_id = 7, text = "Fear" } }))

			assert.is_false(store:hasBook(CLIENT_BOOK_ID))
		end)

		it("refuses a book id that is not a non-empty string", function()
			local snapshot = ledgerWith()

			assert.is_false(snapshot:recordPlaced("", {}))
			assert.is_false(snapshot:recordPlaced(nil, {}))
		end)

		it("refuses a placed set that is not an array", function()
			local snapshot, store = ledgerWith()

			assert.is_false(snapshot:recordPlaced(CLIENT_BOOK_ID, nil))

			assert.is_false(store:hasBook(CLIENT_BOOK_ID))
		end)
	end)

	describe("reading a book back", function()
		it("answers nil for a book that was never recorded", function()
			local snapshot = ledgerWith()

			assert.is_nil(snapshot:getBook(CLIENT_BOOK_ID))
			assert.is_false(snapshot:hasBook(CLIENT_BOOK_ID))
		end)

		it("tells an enrolled book with no highlights from an unknown book", function()
			-- #601 removes what the snapshot holds and the device no longer has;
			-- #602 flags what the snapshot does not hold. Both need "enrolled,
			-- server empty" to read differently from "never pulled".
			local snapshot = ledgerWith()

			snapshot:recordPlaced(CLIENT_BOOK_ID, {})

			assert.are.same({}, snapshot:getBook(CLIENT_BOOK_ID))
			assert.is_true(snapshot:hasBook(CLIENT_BOOK_ID))
		end)

		it("returns the recorded rows", function()
			local snapshot = ledgerWith()

			snapshot:recordPlaced(CLIENT_BOOK_ID, { { server_id = 7, text = "Fear is the mind-killer" } })

			assert.are.same({
				{ server_id = 7, text_hash = "sha256:Fear is the mind-killer" },
			}, snapshot:getBook(CLIENT_BOOK_ID))
		end)

		it("answers before the ledger was opened rather than throwing", function()
			local snapshot = ledgerWith({ init = false })

			assert.is_nil(snapshot:getBook(CLIENT_BOOK_ID))
			assert.is_false(snapshot:hasBook(CLIENT_BOOK_ID))
		end)
	end)

	describe("findRemoved", function()
		--- Enrol a book with the given highlights, then diff it against others
		-- @param recorded table Array of {server_id, text} the pull placed
		-- @param on_device table Array of {text} the book holds now
		-- @return table|nil The diff
		local function diffAfterRecording(recorded, on_device)
			local snapshot = ledgerWith()
			snapshot:recordPlaced(CLIENT_BOOK_ID, recorded)
			return snapshot:findRemoved(CLIENT_BOOK_ID, on_device)
		end

		it("names the server ids the device no longer holds", function()
			local removed = diffAfterRecording({
				{ server_id = 7, text = "Fear is the mind-killer" },
				{ server_id = 12, text = "The spice must flow" },
			}, { { text = "The spice must flow" } })

			assert.are.same({ 7 }, removed.ids)
		end)

		it("finds nothing removed when the book still holds every recorded highlight", function()
			local removed = diffAfterRecording({
				{ server_id = 7, text = "Fear is the mind-killer" },
				{ server_id = 12, text = "The spice must flow" },
			}, {
				{ text = "The spice must flow" },
				{ text = "Fear is the mind-killer" },
			})

			assert.are.same({}, removed.ids)
			assert.is_false(removed.mass_removal)
		end)

		it("ignores highlights the device made that the server has never seen", function()
			local removed = diffAfterRecording({ { server_id = 7, text = "Fear is the mind-killer" } }, {
				{ text = "Fear is the mind-killer" },
				{ text = "made on this device just now" },
			})

			assert.are.same({}, removed.ids)
		end)

		it("keeps a recorded highlight whose text is still somewhere in the book", function()
			-- The server's identity for a highlight is the hash of its text, so
			-- it cannot hold two with one text. Counting occurrences would only
			-- ever remove a highlight the reader still has in front of them.
			local removed = diffAfterRecording({
				{ server_id = 7, text = "Fear is the mind-killer" },
				{ server_id = 8, text = "Fear is the mind-killer" },
			}, { { text = "Fear is the mind-killer" } })

			assert.are.same({}, removed.ids)
		end)

		it("refuses to diff a book that has never pulled", function()
			-- Nothing says whether a missing highlight was deleted here or has
			-- simply never arrived, so a first sync removes nothing.
			local snapshot = ledgerWith()

			assert.is_nil(snapshot:findRemoved(CLIENT_BOOK_ID, { { text = "Fear is the mind-killer" } }))
		end)

		it("removes everything a book enrolled with highlights has lost", function()
			local removed = diffAfterRecording({
				{ server_id = 7, text = "Fear is the mind-killer" },
				{ server_id = 12, text = "The spice must flow" },
			}, {})

			assert.are.same({ 7, 12 }, removed.ids)
		end)

		it("flags an emptied book as a mass removal", function()
			-- Every recorded highlight gone at once, with none left behind, is
			-- as much the signature of a lost sidecar as of a real clear-out.
			local removed = diffAfterRecording({
				{ server_id = 7, text = "Fear is the mind-killer" },
				{ server_id = 12, text = "The spice must flow" },
			}, {})

			assert.is_true(removed.mass_removal)
		end)

		it("flags a book holding a different set entirely as a mass removal", function()
			-- The ledger is keyed by "title|author", so a second file of the
			-- same book reads its ledger while holding its own highlights.
			-- Diffed blind that empties the account for every device, so what
			-- the device still has of its own cannot wave the question away.
			local removed = diffAfterRecording({ { server_id = 7, text = "Fear is the mind-killer" } }, {
				{ text = "a passage highlighted in another copy" },
			})

			assert.are.same({ 7 }, removed.ids)
			assert.is_true(removed.mass_removal)
		end)

		it("does not flag a book that kept some of what it pulled", function()
			-- Highlights deleted one by one leave the rest behind, which no
			-- lost sidecar and no foreign copy ever does.
			local removed = diffAfterRecording({
				{ server_id = 7, text = "Fear is the mind-killer" },
				{ server_id = 12, text = "The spice must flow" },
			}, { { text = "The spice must flow" } })

			assert.are.same({ 7 }, removed.ids)
			assert.is_false(removed.mass_removal)
		end)

		it("does not flag a book enrolled with no highlights at all", function()
			-- Nothing to remove is not a mass removal, however empty the book.
			local removed = diffAfterRecording({}, {})

			assert.are.same({}, removed.ids)
			assert.is_false(removed.mass_removal)
		end)

		it("treats a highlight without usable text as absent", function()
			local removed = diffAfterRecording({ { server_id = 7, text = "Fear is the mind-killer" } }, {
				{ text = "" },
				{ text = JSON_NULL },
			})

			assert.are.same({ 7 }, removed.ids)
			assert.is_true(removed.mass_removal)
		end)

		it("refuses a highlight set that is not a list", function()
			local snapshot = ledgerWith()
			snapshot:recordPlaced(CLIENT_BOOK_ID, { { server_id = 7, text = "Fear is the mind-killer" } })

			assert.is_nil(snapshot:findRemoved(CLIENT_BOOK_ID, nil))
		end)

		it("answers before the ledger was opened rather than throwing", function()
			local snapshot = ledgerWith({ init = false })

			assert.is_nil(snapshot:findRemoved(CLIENT_BOOK_ID, {}))
		end)
	end)

	describe("flagNew", function()
		--- Enrol a book with the given highlights, then flag a push against it
		-- @param recorded table|nil Array of {server_id, text} the pull placed, nil
		--   to leave the book unenrolled
		-- @param pushed table Array of the highlights about to be uploaded
		-- @return number How many were flagged
		-- @return table The pushed highlights, flagged in place
		local function flagAfterRecording(recorded, pushed)
			local snapshot = ledgerWith()
			if recorded then
				snapshot:recordPlaced(CLIENT_BOOK_ID, recorded)
			end
			return snapshot:flagNew(CLIENT_BOOK_ID, pushed), pushed
		end

		it("flags a highlight whose text the snapshot has never held", function()
			local flagged, pushed = flagAfterRecording({ { server_id = 7, text = "Fear is the mind-killer" } }, {
				{ text = "Fear is the mind-killer" },
				{ text = "made on this device just now" },
			})

			assert.are.equal(1, flagged)
			assert.is_nil(pushed[1].is_new)
			assert.is_true(pushed[2].is_new)
		end)

		it("leaves a highlight the pull placed unflagged", function()
			-- Pushing back what the server just sent is an echo, not a decision, so
			-- it must not revive anything the account has since removed.
			local flagged, pushed = flagAfterRecording({
				{ server_id = 7, text = "Fear is the mind-killer" },
				{ server_id = 12, text = "The spice must flow" },
			}, {
				{ text = "Fear is the mind-killer" },
				{ text = "The spice must flow" },
			})

			assert.are.equal(0, flagged)
			assert.is_nil(pushed[1].is_new)
			assert.is_nil(pushed[2].is_new)
		end)

		it("flags everything a book enrolled with no highlights pushes", function()
			local flagged, pushed = flagAfterRecording({}, { { text = "Fear is the mind-killer" } })

			assert.are.equal(1, flagged)
			assert.is_true(pushed[1].is_new)
		end)

		it("flags nothing for a book that has never pulled", function()
			-- A fresh device's sidecar may predate every web deletion the account
			-- has made, and flagging it blind would revive all of them at once. The
			-- book enrols on its first pull and flags from then on.
			local flagged, pushed = flagAfterRecording(nil, { { text = "Fear is the mind-killer" } })

			assert.are.equal(0, flagged)
			assert.is_nil(pushed[1].is_new)
		end)

		it("re-flags a highlight the reader deleted and highlighted again", function()
			-- The passage left the book, so the removal already went out and the
			-- next pull dropped it from the snapshot. Highlighting it again is the
			-- deliberate act the flag exists for.
			local snapshot = ledgerWith()
			snapshot:recordPlaced(CLIENT_BOOK_ID, { { server_id = 7, text = "Fear is the mind-killer" } })
			snapshot:recordPlaced(CLIENT_BOOK_ID, {})

			local pushed = { { text = "Fear is the mind-killer" } }

			assert.are.equal(1, snapshot:flagNew(CLIENT_BOOK_ID, pushed))
			assert.is_true(pushed[1].is_new)
		end)

		it("leaves a highlight without usable text unflagged", function()
			-- The server hashes the text to match it, so text it could not have
			-- hashed matches nothing there either.
			local flagged, pushed = flagAfterRecording({ { server_id = 7, text = "Fear is the mind-killer" } }, {
				{ text = "" },
				{ text = JSON_NULL },
			})

			assert.are.equal(0, flagged)
			assert.is_nil(pushed[1].is_new)
			assert.is_nil(pushed[2].is_new)
		end)

		it("refuses a highlight set that is not a list", function()
			local snapshot = ledgerWith()
			snapshot:recordPlaced(CLIENT_BOOK_ID, { { server_id = 7, text = "Fear is the mind-killer" } })

			assert.are.equal(0, snapshot:flagNew(CLIENT_BOOK_ID, nil))
		end)

		it("answers before the ledger was opened rather than throwing", function()
			local snapshot = ledgerWith({ init = false })

			assert.are.equal(0, snapshot:flagNew(CLIENT_BOOK_ID, { { text = "Fear is the mind-killer" } }))
		end)
	end)

	describe("close", function()
		it("closes the store", function()
			local snapshot, store = ledgerWith()

			snapshot:close()

			assert.is_true(store.closed)
		end)

		it("does nothing when the ledger was never opened", function()
			local snapshot, store = ledgerWith({ init = false })

			snapshot:close()

			assert.is_false(store.closed)
		end)
	end)
end)
