--[[
Stub for KOReader's `random`.

The plugin calls `random.uuid()` once, to name a device that KOReader itself has
not named. A random value would make the resulting id unassertable, so the stub
hands out a fixed sequence instead. The real `uuid()` returns 32 uppercase hex
characters with no dashes unless called as `uuid(true)`; the stub's hyphenated
lowercase values are deliberately unlike it, proving that device_identity
normalises whatever shape it is given:

	random.uuid()  -- "00000000-0000-4000-8000-000000000001"

`random.setNextUuids("...")` queues specific values for a test, and
`random.reset()` (call it in `before_each`) restarts the sequence.
]]

local random = {}

local queued = {}
local issued = 0

--- Return the next UUID in the sequence, or the next queued one
-- @return string A UUID
function random.uuid()
	if #queued > 0 then
		return table.remove(queued, 1)
	end
	issued = issued + 1
	return string.format("00000000-0000-4000-8000-%012d", issued)
end

--- Queue the UUIDs the next calls should return, in order
-- @param ... string The UUIDs to hand out
function random.setNextUuids(...)
	queued = { ... }
end

--- Empty the queue and restart the sequence
function random.reset()
	queued = {}
	issued = 0
end

return random
