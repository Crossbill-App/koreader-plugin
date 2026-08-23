local UI = require("modules/ui")
local UIManager = require("ui/uimanager")
local Trapper = require("ui/trapper")
local UpgradeRequired = require("modules/upgrade_required")
local meta = require("_meta")

describe("UI", function()
	before_each(function()
		stub(UIManager, "show")
	end)

	after_each(function()
		UIManager.show:revert()
	end)

	--- The widget the last call put on screen
	-- @return table The widget
	local function shownWidget()
		return UIManager.show.calls[1].vals[2]
	end

	--- The text of the message the last call put on screen
	-- @return string The message text
	local function shownText()
		return shownWidget().text
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

	describe("showUpgradeRequired", function()
		local REFUSAL = UpgradeRequired.fromResponse(426, {
			detail = {
				min_supported_version = "0.13.0",
				received_version = "0.12.0",
				update_url = "https://github.com/Crossbill-App/koreader-plugin",
			},
		})

		it("names the version the reader has and the one the server wants", function()
			UI.showUpgradeRequired(REFUSAL)

			assert.are.equal(
				"Your Crossbill plugin (0.12.0) is too old for this server. "
					.. "Please update to 0.13.0 or newer.\n"
					.. "https://github.com/Crossbill-App/koreader-plugin",
				shownText()
			)
		end)

		it("asks the reader nothing, so a sync at shutdown is never held up", function()
			-- An autosync fires while the book or the device is closing, with
			-- nobody there to dismiss a dialog.
			UI.showUpgradeRequired(REFUSAL)

			assert.is_nil(shownWidget().buttons)
		end)

		it("stays up long enough to read an address off it", function()
			UI.showUpgradeRequired(REFUSAL)

			assert.are.equal(10, shownWidget().timeout)
		end)

		it("still says something when there is no refusal to go on", function()
			UI.showUpgradeRequired(nil)

			assert.is_string(shownText())
		end)
	end)

	describe("showAbout", function()
		it("names the version and the address the plugin comes from", function()
			-- Read from _meta rather than written out, so the release workflow's
			-- version bump cannot leave the dialog naming an older one.
			UI.showAbout()

			assert.is_truthy(shownText():find(meta.version, 1, true))
			assert.is_truthy(shownText():find(meta.homepage, 1, true))
		end)

		it("stays on screen until the reader dismisses it", function()
			-- A URL that vanishes mid-transcription is worse than one to tap away.
			UI.showAbout()

			assert.is_nil(shownWidget().timeout)
		end)
	end)

	describe("dismiss", function()
		before_each(function()
			stub(UIManager, "close")
		end)

		after_each(function()
			UIManager.close:revert()
		end)

		it("takes down the message it is handed", function()
			-- The stub records a copy rather than the widget itself, so the
			-- message is recognised by its text.
			UI.dismiss(UI.showSyncingMessage())

			assert.are.equal("Syncing with Crossbill...", UIManager.close.calls[1].vals[2].text)
		end)

		it("does nothing when there is no message to take down", function()
			-- An autosync never put one up, and it calls this all the same.
			UI.dismiss(nil)

			assert.are.same({}, UIManager.close.calls)
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
	describe("showUpdateInstalled", function()
		local handlers

		before_each(function()
			stub(UIManager, "askForRestart")
			handlers = UIManager.event_handlers
		end)

		after_each(function()
			UIManager.askForRestart:revert()
			UIManager.event_handlers = handlers
		end)

		it("leaves the restart to KOReader, which knows what the device can do", function()
			UI.showUpdateInstalled("0.14.0")

			assert.stub(UIManager.askForRestart).was_called_with(UIManager, "Crossbill Sync 0.14.0 is installed.")
			assert.are.equal(0, #UIManager.show.calls)
		end)

		it("says so itself where KOReader would say nothing", function()
			-- `askForRestart` returns without showing anything when the
			-- device's event handlers are not there, and an install nobody is
			-- told about is one the reader cannot know worked.
			UIManager.event_handlers = nil

			UI.showUpdateInstalled("0.14.0")

			assert.stub(UIManager.askForRestart).was_not_called()
			assert.are.equal("Crossbill Sync 0.14.0 is installed.", shownText())
		end)

		it("stays up long enough to read", function()
			UIManager.event_handlers = nil

			UI.showUpdateInstalled("0.14.0")

			assert.are.equal(10, shownWidget().timeout)
		end)
	end)
end)
