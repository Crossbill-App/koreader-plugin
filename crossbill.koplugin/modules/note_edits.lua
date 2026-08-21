--[[
Note Edit Stamping Module for Crossbill Sync

KOReader refreshes an annotation's datetime_updated only when a note is added or
removed, not when its text is edited (ReaderBookmark:setBookmarkNote raises
AnnotationsModified only when the annotation changes type). Crossbill merges
note edits by recency, so an edited note would look unchanged to the server and
lose to the copy it already holds.

The plugin therefore remembers the note it last synced for each highlight, in
crossbill_note_seen on the annotation item itself, and stamps the edits it finds
before the highlights are extracted for upload.
]]

local NoteEdits = {}

-- The annotation field holding the note text this module last saw. It is this
-- module's own bookkeeping, but the importer writes it too, so that a highlight
-- pulled from the server starts out agreeing with the note the server sent.
NoteEdits.SEEN_FIELD = "crossbill_note_seen"

--- Stamp every highlight whose note changed since the last sync
-- A highlight seen for the first time is stamped only when it already carries a
-- note. Earlier plugin versions did upload notes, so the server usually holds
-- the same text and the fresh stamp changes nothing; when the two differ, this
-- one-time-per-device stamp makes the local text win whatever its real age.
-- Between devices the merge is therefore last-sync-wins, not last-edit-wins:
-- KOReader records no edit time for note text, so sync time is the best
-- ordering available.
-- @param annotations table The reader's live annotation array
-- @return number Number of highlights stamped
function NoteEdits.stamp(annotations)
	local now = os.date("%Y-%m-%d %H:%M:%S")
	local stamped = 0

	for _, item in ipairs(annotations) do
		if item.drawer then
			local note = item.note or ""
			local seen = item[NoteEdits.SEEN_FIELD]
			if (seen == nil and note ~= "") or (seen ~= nil and seen ~= note) then
				item.datetime_updated = now
				stamped = stamped + 1
			end
			item[NoteEdits.SEEN_FIELD] = note
		end
	end

	return stamped
end

return NoteEdits
