--[[
Stand-in for KOReader's `libs/libkoreader-lfs`.

KOReader bundles LuaFileSystem under its own name. The library is the same one
LuaRocks installs, so this hands over the real thing rather than a fake: the
installer's staging and swap are tested against real directories, which is the
only way a mistake there shows up before it removes someone's plugin.
]]

return require("lfs")
