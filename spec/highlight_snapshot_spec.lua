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
