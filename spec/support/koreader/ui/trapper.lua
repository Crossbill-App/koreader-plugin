--[[
Stub for KOReader's `ui/trapper`.

The real Trapper shows a widget and yields the running coroutine, resuming it
with the reader's answer once a button is tapped. Neither the widget nor the
event loop exists under busted, so this stub keeps only the shape the plugin
depends on: `confirm` blocks and hands back a boolean.

`Trapper.answer` is the control surface -- set it to what the next `confirm`
should return; `Trapper.asked` holds the arguments of every call made, so a spec
can assert on the wording the reader would have seen.
]]

local Trapper = {}

-- What the next confirm answers, and what every call was asked
Trapper.answer = true
Trapper.asked = {}

--- Ask the reader a yes/no question
-- @param text string The question
-- @param cancel_text string|nil Label of the declining button
-- @param ok_text string|nil Label of the confirming button
-- @return boolean The queued answer
function Trapper:confirm(text, cancel_text, ok_text)
	table.insert(self.asked, { text = text, cancel_text = cancel_text, ok_text = ok_text })
	return self.answer
end

--- Run a function inside a coroutine, as the real wrapper does
-- @param func function The function to run
-- @return boolean Whether the coroutine started
function Trapper:wrap(func)
	return coroutine.resume(coroutine.create(func))
end

--- Forget the questions asked and go back to answering yes
function Trapper.reset()
	Trapper.answer = true
	Trapper.asked = {}
end

return Trapper
