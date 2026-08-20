--[[
Stub for KOReader's `ui/widget/textviewer`.

Stands in for the plain-text viewer the plugin falls back to when the rich
digest viewer is unavailable. As with the other widgets, it only has to be
requirable and to remember what it was built with.
]]

local TextViewer = {}
TextViewer.__index = TextViewer

--- Build a text viewer
-- @param opts table The viewer's fields (title, text, ...)
-- @return table The viewer
function TextViewer:new(opts)
	return setmetatable(opts or {}, TextViewer)
end

return TextViewer
