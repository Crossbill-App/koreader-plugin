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

--- Stamp every highlight whose note changed since the last sync
-- A highlight seen for the first time is stamped only when it already carries a
-- note: that note was written before the plugin started tracking edits and has
-- never reached the server, so it should win rather than be reverted.
-- @param annotations table The reader's live annotation array
-- @return number Number of highlights stamped
function NoteEdits.stamp(annotations)
	local now = os.date("%Y-%m-%d %H:%M:%S")
	local stamped = 0

	for _, item in ipairs(annotations) do
		if item.drawer then
			local note = item.note or ""
			local seen = item.crossbill_note_seen
			if (seen == nil and note ~= "") or (seen ~= nil and seen ~= note) then
				item.datetime_updated = now
				stamped = stamped + 1
			end
			item.crossbill_note_seen = note
		end
	end

	return stamped
end

return NoteEdits
