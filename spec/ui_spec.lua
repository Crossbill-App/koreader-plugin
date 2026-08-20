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
	end)
end)
