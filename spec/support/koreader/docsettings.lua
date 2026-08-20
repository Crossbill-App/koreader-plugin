--[[
Stub for KOReader's `docsettings`.

The real module reads a sidecar file next to the book. Here, specs register the
settings a given document path should appear to have:

	DocSettings.setFixture("/books/dune.epub", { doc_pages = 412 })
	DocSettings.setFixture("/books/dune.epub", { annotations = { ... } })

Opening a path with no fixture yields empty settings, which is what KOReader
does for a book it has never opened. Call `DocSettings.reset()` in `before_each`
so fixtures do not leak between tests.
]]

local DocSettings = {}

local fixtures = {}

local Handle = {}
Handle.__index = Handle

--- Read one key out of the document's settings
-- @param key string The setting key
-- @return mixed The stored value, or nil when unset
function Handle:readSetting(key)
	return self._settings[key]
end

--- Open the settings for a document
-- @param doc_path string Path to the document
-- @return table A settings handle
function DocSettings:open(doc_path)
	return setmetatable({ _settings = fixtures[doc_path] or {} }, Handle)
end

--- Declare the settings that a document path should report
-- @param doc_path string Path to the document
-- @param settings table The settings table to serve
function DocSettings.setFixture(doc_path, settings)
	fixtures[doc_path] = settings
end

--- Forget every registered fixture
function DocSettings.reset()
	fixtures = {}
end

return DocSettings
