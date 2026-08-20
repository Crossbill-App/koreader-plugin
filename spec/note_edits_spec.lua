local NoteEdits = require("modules/note_edits")

--- Build a highlight annotation, which is anything carrying a drawer
-- @param fields table|nil Overrides for the annotation
-- @return table An annotation item
local function highlight(fields)
	local item = { drawer = "lighten", text = "the spice must flow" }
	for key, value in pairs(fields or {}) do
		item[key] = value
	end
	return item
end

--- Build a page bookmark, which is an annotation without a drawer
-- @param fields table|nil Overrides for the annotation
-- @return table An annotation item
local function bookmark(fields)
	local item = { text = "in Chapter 2" }
	for key, value in pairs(fields or {}) do
		item[key] = value
	end
	return item
end

describe("NoteEdits", function()
	describe("stamp", function()
		it("stamps a note the plugin has never seen", function()
			local item = highlight({ note = "remember this" })

			assert.are.equal(1, NoteEdits.stamp({ item }))
			assert.is_not_nil(item.datetime_updated)
		end)

		it("leaves a first-seen highlight without a note alone", function()
			-- Nothing was edited: there is no note for the server to lose.
			local item = highlight()

			assert.are.equal(0, NoteEdits.stamp({ item }))
			assert.is_nil(item.datetime_updated)
		end)

		it("stamps a note whose text changed since the last sync", function()
			local item = highlight({ note = "second thoughts", crossbill_note_seen = "first thoughts" })

			assert.are.equal(1, NoteEdits.stamp({ item }))
			assert.is_not_nil(item.datetime_updated)
		end)

		it("stamps a note that was removed since the last sync", function()
			local item = highlight({ crossbill_note_seen = "remember this" })

			assert.are.equal(1, NoteEdits.stamp({ item }))
			assert.is_not_nil(item.datetime_updated)
		end)

		it("stamps a note added to a highlight that had none", function()
			local item = highlight({ note = "remember this", crossbill_note_seen = "" })

			assert.are.equal(1, NoteEdits.stamp({ item }))
			assert.is_not_nil(item.datetime_updated)
		end)

		it("leaves an unchanged note alone", function()
			local item =
				highlight({ note = "remember this", crossbill_note_seen = "remember this", datetime_updated = nil })

			assert.are.equal(0, NoteEdits.stamp({ item }))
			assert.is_nil(item.datetime_updated)
		end)

		it("keeps the existing datetime_updated when nothing changed", function()
			-- KOReader's own stamp, from adding the note, must survive.
			local item = highlight({
				note = "remember this",
				crossbill_note_seen = "remember this",
				datetime_updated = "2024-05-01 12:00:00",
			})

			NoteEdits.stamp({ item })

			assert.are.equal("2024-05-01 12:00:00", item.datetime_updated)
		end)

		it("overwrites an older datetime_updated when the note changed", function()
			local item = highlight({
				note = "second thoughts",
				crossbill_note_seen = "first thoughts",
				datetime_updated = "2024-05-01 12:00:00",
			})

			NoteEdits.stamp({ item })

			assert.are_not.equal("2024-05-01 12:00:00", item.datetime_updated)
		end)

		it("records the note it saw, so the next sync compares against it", function()
			local item = highlight({ note = "remember this" })

			NoteEdits.stamp({ item })

			assert.are.equal("remember this", item.crossbill_note_seen)
		end)

		it("records an empty string for a highlight with no note", function()
			-- Storing "" rather than nil is what tells a later run the highlight
			-- has been seen, so a note added afterwards counts as an edit.
			local item = highlight()

			NoteEdits.stamp({ item })

			assert.are.equal("", item.crossbill_note_seen)
		end)

		it("stamps nothing on a second pass over the same highlights", function()
			local items = { highlight({ note = "remember this" }), highlight({ note = "and this" }) }

			assert.are.equal(2, NoteEdits.stamp(items))
			assert.are.equal(0, NoteEdits.stamp(items))
		end)

		it("ignores page bookmarks, which carry no note to sync", function()
			local item = bookmark({ note = "not a highlight note" })

			assert.are.equal(0, NoteEdits.stamp({ item }))
			assert.is_nil(item.datetime_updated)
			assert.is_nil(item.crossbill_note_seen)
		end)

		it("counts only the highlights it stamped", function()
			local items = {
				highlight({ note = "new" }),
				highlight({ note = "same", crossbill_note_seen = "same" }),
				highlight({ note = "changed", crossbill_note_seen = "was" }),
				bookmark(),
			}

			assert.are.equal(2, NoteEdits.stamp(items))
		end)

		it("stamps every edit in one pass with the same timestamp", function()
			local first = highlight({ note = "one" })
			local second = highlight({ note = "two" })

			NoteEdits.stamp({ first, second })

			assert.are.equal(first.datetime_updated, second.datetime_updated)
		end)

		it("writes the timestamp in the format KOReader uses", function()
			local item = highlight({ note = "remember this" })

			NoteEdits.stamp({ item })

			assert.is_truthy(item.datetime_updated:match("^%d%d%d%d%-%d%d%-%d%d %d%d:%d%d:%d%d$"))
		end)

		it("handles an empty annotation list", function()
			assert.are.equal(0, NoteEdits.stamp({}))
		end)
	end)
end)
