--[[
Stub for KOReader's `device`.

The real module probes the hardware it is running on. The plugin only reads
`Device.model`, to label the device a highlight or reading session came from, so
that is all the stub carries. A spec sets it for the device it wants to describe:

	Device.model = "PocketBook628"

`DEFAULT_MODEL` is restored by `Device.reset()`; call it in `before_each` so a
model does not leak between tests.
]]

local Device = {}

local DEFAULT_MODEL = "TestReader"

Device.model = DEFAULT_MODEL

--- Restore the model a fresh device reports
function Device.reset()
	Device.model = DEFAULT_MODEL
end

return Device
