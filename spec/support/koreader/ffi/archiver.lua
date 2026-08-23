--[[
Stand-in for koreader-base's `ffi/archiver`.

libarchive is not available outside KOReader, so the reading is faked while the
writing is real: a spec describes an archive's entries with `setEntries`, and
`extractToPath` creates those files and directories on disk for real. That keeps
the installer's own work -- deciding what to extract where, then swapping the
directories -- under test against a real filesystem.

The `Reader` surface matches the real one where the installer touches it:
`open` answers true or nil, `iterate` walks entries carrying `path` and `mode`,
`extractToPath` takes an entry key and a destination, and `err` explains a
failure. A spec makes opening fail with `failOpenWith`.
]]

local lfs = require("lfs")

local Reader = {}
Reader.__index = Reader

-- What the next opened archive contains, as an ordered list of
-- { path = "...", mode = "file"|"directory", content = "..." }
local entries = {}

-- What the next `open` fails with, or nil to let it succeed
local open_failure = nil

--- Describe the archive the next `open` will read
-- @param list table Ordered entries, each with path, mode and optional content
local function setEntries(list)
	entries = list or {}
end

--- Make the next `open` fail, as a truncated or corrupt archive would
-- @param message string|nil What to report, nil to let opening succeed
local function failOpenWith(message)
	open_failure = message
end

--- Create a reader
-- @return table The reader
function Reader:new()
	return setmetatable({ entries = {}, index = 0, err = nil }, Reader)
end

--- Open an archive, which must exist on disk as the real one must
-- @param filepath string The archive
-- @return boolean|nil True when opened, nil otherwise
function Reader:open(filepath)
	self.err = nil

	if open_failure then
		self.err = open_failure
		return nil
	end

	if not filepath or lfs.attributes(filepath, "mode") ~= "file" then
		self.err = "no such archive"
		return nil
	end

	self.filepath = filepath
	self.index = 0
	self.entries = {}

	for position, entry in ipairs(entries) do
		local copy = {
			path = entry.path,
			mode = entry.mode,
			content = entry.content,
			size = entry.content and #entry.content or 0,
			index = position,
		}
		self.entries[position] = copy
		self.entries[entry.path] = copy
	end

	return true
end

--- Advance to the next entry
-- @return table|nil The entry, nil at the end
function Reader:next()
	self.index = math.floor(self.index) + 1
	return self.entries[self.index]
end

--- Walk the entries from the start
-- @return function, table The iterator and the reader
function Reader:iterate()
	self.index = 0
	return self.next, self
end

--- Write one entry to a path, creating a file or a directory as it says
-- @param key string|number The entry's path or index
-- @param dest_path string Where to create it
-- @return boolean True when it was created
function Reader:extractToPath(key, dest_path)
	self.err = nil
	local entry = self.entries[key]

	if not entry or not dest_path then
		self.err = "no such path"
		return false
	end

	if entry.mode == "directory" then
		if lfs.attributes(dest_path, "mode") ~= "directory" then
			local ok, err = lfs.mkdir(dest_path)
			if not ok then
				self.err = err
				return false
			end
		end
		return true
	end

	local handle, err = io.open(dest_path, "wb")
	if not handle then
		self.err = err
		return false
	end

	handle:write(entry.content or "")
	handle:close()
	return true
end

--- Release the archive
function Reader:close()
	self.filepath = nil
	self.index = 0
end

return {
	Reader = Reader,
	setEntries = setEntries,
	failOpenWith = failOpenWith,
}
