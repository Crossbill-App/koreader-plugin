--[[
Stand-in for koreader-base's `ffi/util`.

Only the handful of helpers the update installer reaches for. The path and
directory ones do the real work against the real filesystem, so a spec that
stages and swaps directories is testing what will happen on a device rather
than what a mock was told to say.

Two are not real, because they cannot be here:

  * `df` reports whatever a spec set with `setFreeSpace`, so the refusal to
    install without room is exercisable rather than hypothetical.
  * `fsyncDirectory` is a no-op; durability is not observable in a test.
]]

local lfs = require("lfs")

local util = {}

-- What `df` reports until a spec says otherwise: room enough for anything
util.free_space = 1024 * 1024 * 1024

--- Set what the next `df` reports as available
-- @param bytes number The free space to report
function util.setFreeSpace(bytes)
	util.free_space = bytes
end

--- Report the filesystem's size, free space and available space
-- The real one reads statvfs; this reports what the spec asked for.
-- @return number, number, number Total, free and available bytes
function util.df()
	return util.free_space, util.free_space, util.free_space
end

--- The last component of a path, with any trailing slashes ignored
-- @param path string The path
-- @return string The last component
function util.basename(path)
	local stripped = path:match(".*[^/]") or "/"
	return stripped:match("[^/]+$") or stripped
end

--- Everything before the last component of a path
-- @param path string The path
-- @return string The parent
function util.dirname(path)
	local stripped = path:match(".*[^/]") or "/"
	local parent = stripped:match("^(.*)/[^/]+$")

	if not parent or parent == "" then
		return stripped:sub(1, 1) == "/" and "/" or "."
	end

	return parent
end

--- Join two path components with a single separator
-- @param path1 string The first component
-- @param path2 string The second component
-- @return string The joined path
function util.joinPath(path1, path2)
	return (path1:gsub("/+$", "")) .. "/" .. (path2:gsub("^/+", ""))
end

--- Remove a directory and everything in it
-- The real recursive delete, so a spec can assert the old copy is gone and
-- would notice a path pointed one level too high.
-- @param dir string The directory to remove
-- @return boolean|nil True on success, nil and a message otherwise
function util.purgeDir(dir)
	if lfs.attributes(dir, "mode") ~= "directory" then
		return nil, "not a directory: " .. tostring(dir)
	end

	for entry in lfs.dir(dir) do
		if entry ~= "." and entry ~= ".." then
			local path = util.joinPath(dir, entry)
			local ok, err
			if lfs.attributes(path, "mode") == "directory" then
				ok, err = util.purgeDir(path)
			else
				ok, err = os.remove(path)
			end
			if not ok then
				return ok, err
			end
		end
	end

	return lfs.rmdir(dir)
end

--- Flush a directory entry to disk, which a test cannot observe
function util.fsyncDirectory() end

return util
