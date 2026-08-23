--[[
Stub for KOReader's `ui/widget/confirmbox`.

Like the InfoMessage stub, it keeps the fields it was built with and nothing
else. A spec reads the question and the button labels off the widget handed to
`UIManager:show`, and calls `ok_callback` itself to act as the reader pressing
the button:

	stub(UIManager, "show")
	UI.showUpdateAvailable(result, on_install)
	UIManager.show.calls[1].vals[2].ok_callback()
]]

local ConfirmBox = {}
ConfirmBox.__index = ConfirmBox

--- Build a confirmation widget
-- @param opts table The widget's fields (text, ok_text, ok_callback, ...)
-- @return table The widget
function ConfirmBox:new(opts)
	return setmetatable(opts or {}, ConfirmBox)
end

return ConfirmBox
