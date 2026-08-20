--[[
Stub for KOReader's `json`.

The plugin's own parsing and serialising happens inside `modules/network` and
`modules/digest_cache`, neither of which is exercised under busted: a spec fakes
the network module rather than encoding anything. What is left is one call made
at load time, `JSON.decode("[]")` in `modules/api_client`, which exists purely to
obtain the decoder's marker for an empty array -- the value a JSON library hands
back for `[]` so that it can be re-encoded as an array and not as an object.

So this stub implements exactly that one case and refuses the rest loudly, rather
than pretending to be a JSON library. Reaching one of those errors means a spec
has started covering code that really does parse JSON; give it a real decoder
then, do not widen the stub.
]]

local json = {}

-- Stands in for the marker a real decoder returns for `[]`. Its identity is
-- what matters -- code checks whether a value is this marker -- so a spec can
-- compare against `json.EMPTY_ARRAY`.
json.EMPTY_ARRAY = setmetatable({}, {
	__tostring = function()
		return "json:[]"
	end,
})

--- Decode a JSON string
-- @param text string The JSON to decode; only "[]" is supported
-- @return table The empty-array marker
function json.decode(text)
	if text == "[]" then
		return json.EMPTY_ARRAY
	end
	error("json stub: decode is only implemented for '[]', got: " .. tostring(text))
end

--- Encode a Lua value as JSON
-- @param value mixed The value to encode
function json.encode(value)
	error("json stub: encode is not implemented, got: " .. type(value))
end

return json
