local UI = require("modules/ui")
local UIManager = require("ui/uimanager")
local Trapper = require("ui/trapper")

describe("UI", function()
	before_each(function()
		stub(UIManager, "show")
	end)

	after_each(function()
		UIManager.show:revert()
	end)

	--- The text of the message the last call put on screen
	-- @return string The message text
	local function shownText()
		return UIManager.show.calls[1].vals[2].text
	end

	describe("showSyncSuccess", function()
		it("reports what the push uploaded, one line per fact", function()
			UI.showSyncSuccess({ highlights_created = 3, highlights_skipped = 7 })

			assert.are.equal("Uploaded 3 new highlights.", shownText())
		end)

		it("says the highlights are up to date when nothing happened at all", function()
			UI.showSyncSuccess({})

			assert.are.equal("Highlights are up to date.", shownText())
		end)

		it("says the highlights are up to date when the pull found them matching", function()
			UI.showSyncSuccess({ pull = { unchanged = true, inserted = 0 } })

			assert.are.equal("Highlights are up to date.", shownText())
		end)

		it("reports what the pull brought back", function()
			UI.showSyncSuccess({ highlights_created = 1, pull = { inserted = 12 } })

			assert.are.equal("Uploaded 1 new highlights.\nPulled 12 highlights from Crossbill.", shownText())
		end)

		it("sums the two kinds of skipped highlight into one count", function()
			UI.showSyncSuccess({
				pull = { inserted = 2, skipped_unplaceable = 3, skipped_invalid = 4 },
			})

			assert.are.equal("Pulled 2 highlights from Crossbill.\nSkipped: 7", shownText())
		end)

		it("leaves every zero-valued line out", function()
			UI.showSyncSuccess({
				highlights_created = 0,
				pull = { inserted = 0, skipped_unplaceable = 0, skipped_invalid = 1 },
			})

			assert.are.equal("Skipped: 1", shownText())
		end)

		it("reports a pull that failed, after the upload that succeeded", function()
			UI.showSyncSuccess({
				highlights_created = 3,
				pull_error = "Book not found on Crossbill",
			})

			assert.are.equal("Uploaded 3 new highlights.\nPull failed: Book not found on Crossbill", shownText())
		end)

		it("shows the message long enough to read it", function()
			UI.showSyncSuccess({ pull = { inserted = 1 } })

			assert.are.equal(6, UIManager.show.calls[1].vals[2].timeout)
		end)

		it("reports what the push withdrew from the reader's devices", function()
			-- Removals were invisible before: a deletion that reached the
			-- server looked exactly like a sync that did nothing.
			UI.showSyncSuccess({ highlights_created = 1, highlights_removed = 2 })

			assert.are.equal("Uploaded 1 new highlights.\n2 removed from your devices.", shownText())
		end)

		it("leaves the removal line out when nothing was removed", function()
			UI.showSyncSuccess({ highlights_created = 1, highlights_removed = 0 })

			assert.are.equal("Uploaded 1 new highlights.", shownText())
		end)
	end)

	describe("confirmRemoveAll", function()
		before_each(function()
			Trapper.reset()
		end)

		--- Ask inside a coroutine, as the wrapped sync does
		-- @return boolean What the confirmation answered
		local function askWrapped()
			local answer
			Trapper:wrap(function()
				answer = UI.confirmRemoveAll(3)
			end)
			return answer
		end

		it("names how many highlights would leave the reader's devices", function()
			askWrapped()

			assert.are.equal("Remove all 3 highlights of this book from your devices?", Trapper.asked[1].text)
		end)

		it("labels the buttons by what they do", function()
			askWrapped()

			assert.are.equal("Remove", Trapper.asked[1].ok_text)
			assert.are.equal("Keep", Trapper.asked[1].cancel_text)
		end)

		it("passes on the reader's answer", function()
			Trapper.answer = true
			assert.is_true(askWrapped())

			Trapper.answer = false
			assert.is_false(askWrapped())
		end)

		it("refuses outside a coroutine rather than answering for the reader", function()
			-- Unwrapped, the real Trapper picks "OK" by itself, which would
			-- remove highlights nobody was ever asked about.
			assert.is_false(UI.confirmRemoveAll(3))
			assert.are.same({}, Trapper.asked)
		end)
	end)
end)
