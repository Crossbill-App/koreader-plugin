--[[
Stub for KOReader's `ui/widget/infomessage`.

Painting is not observable outside the reader, so the stub keeps the fields it
was constructed with and nothing else. A spec reads them off the widget handed
to `UIManager:show`:

	stub(UIManager, "show")
	UI.showMessage("done", 3)
	assert.are.equal("done", UIManager.show.calls[1].vals[2].text)
]]

local InfoMessage = {}
InfoMessage.__index = InfoMessage

--- Build a message widget
-- @param opts table The widget's fields (text, timeout, ...)
-- @return table The widget
function InfoMessage:new(opts)
	return setmetatable(opts or {}, InfoMessage)
end

return InfoMessage
