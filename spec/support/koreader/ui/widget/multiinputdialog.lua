--[[
Stub for KOReader's `ui/widget/multiinputdialog`.

The plugin builds one for the server settings dialog. Driving that dialog needs
a running reader, so the stub exists to make the module requirable and to keep
the fields it was given; the methods the plugin calls on it are no-ops.
]]

local MultiInputDialog = {}
MultiInputDialog.__index = MultiInputDialog

--- Build a dialog
-- @param opts table The dialog's fields (title, fields, buttons, ...)
-- @return table The dialog
function MultiInputDialog:new(opts)
	return setmetatable(opts or {}, MultiInputDialog)
end

--- Return the text of each input, empty until a spec fills them in
-- @return table Array of field values
function MultiInputDialog:getFields()
	return self.field_values or {}
end

--- Focus the dialog's first input
function MultiInputDialog:onShowKeyboard() end

return MultiInputDialog
