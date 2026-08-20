--[[
Stub for KOReader's `gettext`.

The plugin binds it as `_` and calls it on every user-facing string. There are no
translations to serve under busted, and a spec asserting on a message wants the
source string anyway, so this returns its argument unchanged -- which is exactly
what the real module does for an untranslated locale.
]]

--- Translate a string
-- @param text string The source string
-- @return string The same string
return function(text)
	return text
end
