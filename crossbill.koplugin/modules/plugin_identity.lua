--[[
Plugin Identity for Crossbill

Every string the plugin names itself with, derived from the one name in
`_meta.lua`: the settings key, the database filenames, the dispatcher action
ids, the event names, the menu key and the label a reader sees.

This exists for the side-by-side test build. `scripts/copy_to_pocketbook.sh`
installs a second copy of the plugin that has to keep its own settings, its own
databases and its own gesture bindings, or it overwrites the production
plugin's as it runs. That used to be a dozen seds over half the source tree,
one per string, each of which had to be remembered when a new key or database
was added -- and forgetting one looked like a plugin bug on a device rather
than a build mistake. The script now renames the plugin in `_meta.lua` and
everything below follows from that.

Which means the derivations are load-bearing in the other direction too: for
the name "Crossbill" every string here must come out byte-identical to what
readers already have on their devices, or an update silently loses their
settings, their reading sessions and their gestures. `spec/plugin_identity_spec.lua`
pins each of them literally for exactly that reason.
]]

local meta = require("_meta")

local PluginIdentity = {}

--- Derive the identity strings from a plugin name
-- Pure, so a spec can ask what any name would give without a second _meta.
-- @param name string The plugin's name, as `_meta.lua` spells it
-- @return table The display name, the namespace and the event prefix
function PluginIdentity.derive(name)
	-- Lowercase with whitespace as underscores: the shape of a settings key and
	-- of a database filename ("Crossbill Test" -> "crossbill_test").
	local namespace = name:lower():gsub("%s+", "_")
	-- Whitespace closed up, case kept: the shape of an event name, which is
	-- CamelCase because KOReader dispatches it as `on<Event>` ("Crossbill Test"
	-- -> "CrossbillTest").
	local event_prefix = name:gsub("%s+", "")

	return {
		display_name = name,
		namespace = namespace,
		event_prefix = event_prefix,
	}
end

-- This plugin's own identity, alongside the function. Copied field by field so
-- that adding a derivation above is the whole change.
for field, value in pairs(PluginIdentity.derive(meta.name)) do
	PluginIdentity[field] = value
end

return PluginIdentity
