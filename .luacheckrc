-- luacheck configuration for the Crossbill KOReader plugin.
-- KOReader runs plugins on LuaJIT.
std = "luajit"

-- Globals KOReader injects into the plugin environment.
read_globals = {
	"G_reader_settings",
}

-- KOReader callbacks and constructors have fixed signatures, so unused
-- parameters (self, ges_ev, ...) are expected rather than a smell.
unused_args = false

-- stylua owns line width (see .stylua.toml).
max_line_length = false

exclude_files = {
	-- Captured KOReader metadata used as a test fixture, not our source.
	"examples/",
}

-- Specs run under busted, which injects describe/it/assert and friends.
files["spec/**/*_spec.lua"] = {
	std = "luajit+busted",
}
