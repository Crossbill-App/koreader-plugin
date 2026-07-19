--[[
KOReader user patch: show the Crossbill menu on the first page of Tools.

KOReader appends plugin menu entries after all built-in Tools entries, which
pushes Crossbill onto the second page. This patch inserts the Crossbill menu
key at the top of the reader Tools menu order instead.

Install by copying this file to the koreader/patches/ directory on the device
(copy_to_pocketbook.sh does this automatically). The "2-" prefix makes
KOReader apply it after setup, before the UI is built.
]]

local ok, reader_order = pcall(require, "ui/elements/reader_menu_order")
if ok and reader_order and type(reader_order.tools) == "table" then
	table.insert(reader_order.tools, 1, "crossbill_sync")
end
