local UI = require("modules/ui")
local UIManager = require("ui/uimanager")

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
		it("reports what the push uploaded", function()
			UI.showSyncSuccess({ highlights_created = 3, highlights_skipped = 7 })

			assert.are.equal("Uploaded 3 new highlights (7 already there).", shownText())
		end)

		it("counts a sync that uploaded nothing as zero rather than omitting it", function()
			UI.showSyncSuccess({})

			assert.are.equal("Uploaded 0 new highlights (0 already there).", shownText())
		end)

		it("says nothing about a pull that did not happen", function()
			-- A fixed-layout book is not pulled, and that is not worth reporting.
			UI.showSyncSuccess({ highlights_created = 1, highlights_skipped = 0 })

			assert.is_nil(shownText():find("Pulled", 1, true))
			assert.is_nil(shownText():find("up to date", 1, true))
		end)

		it("reports what the pull brought back", function()
			UI.showSyncSuccess({ highlights_created = 1, highlights_skipped = 0, pull = { inserted = 12 } })

			assert.is_truthy(shownText():find("Pulled 12 from Crossbill.", 1, true))
		end)

		it("says the highlights already matched instead of pulling zero", function()
			UI.showSyncSuccess({ pull = { unchanged = true, inserted = 0 } })

			assert.is_truthy(shownText():find("Highlights already up to date.", 1, true))
			assert.is_nil(shownText():find("Pulled", 1, true))
		end)

		it("reports both kinds of skipped highlight", function()
			UI.showSyncSuccess({
				pull = { inserted = 2, skipped_unplaceable = 3, skipped_invalid = 4 },
			})

			assert.is_truthy(shownText():find("Skipped: 3 without position, 4 not in this book.", 1, true))
		end)

		it("mentions skips even when only one kind occurred", function()
			UI.showSyncSuccess({ pull = { inserted = 2, skipped_invalid = 1 } })

			assert.is_truthy(shownText():find("Skipped: 0 without position, 1 not in this book.", 1, true))
		end)

		it("stays quiet about skips when there were none", function()
			UI.showSyncSuccess({ pull = { inserted = 2, skipped_unplaceable = 0, skipped_invalid = 0 } })

			assert.is_nil(shownText():find("Skipped", 1, true))
		end)

		it("reports a pull that failed, after the upload that succeeded", function()
			UI.showSyncSuccess({
				highlights_created = 3,
				highlights_skipped = 0,
				pull_error = "Book not found on Crossbill",
			})

			assert.are.equal(
				"Uploaded 3 new highlights (0 already there). Pull failed: Book not found on Crossbill",
				shownText()
			)
		end)

		it("joins every part into a single message", function()
			UI.showSyncSuccess({
				highlights_created = 1,
				highlights_skipped = 2,
				pull = { inserted = 5, skipped_unplaceable = 1, skipped_invalid = 0 },
			})

			assert.are.equal(
				"Uploaded 1 new highlights (2 already there). Pulled 5 from Crossbill. "
					.. "Skipped: 1 without position, 0 not in this book.",
				shownText()
			)
		end)

		it("shows the message long enough to read the whole summary", function()
			UI.showSyncSuccess({ pull = { inserted = 1 } })

			assert.are.equal(4, UIManager.show.calls[1].vals[2].timeout)
		end)
	end)
end)
