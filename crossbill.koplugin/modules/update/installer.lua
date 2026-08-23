--[[
Update Installer for Crossbill Sync

Replaces the plugin on disk with a newer release. This is the only code in the
plugin that destroys anything, and the only code that runs bytes fetched from
the network, so both are hedged deliberately.

Nothing is installed that is not signed by a key the plugin already carries.
Every way of being unable to check that -- a KOReader too old to ship LibreSSL,
a library that will not load, a release with no signature attached -- refuses
just as firmly as a signature that does not match, and the reader is told to
install by hand instead. Verification whose failure is survivable is not
verification.

The replacement is staged beside the plugin and swapped in, rather than written
over the plugin in place. A staging directory that fails halfway is thrown away
and the reader still has a working plugin; a plugin overwritten halfway is a
mixture of two versions that loads and misbehaves. The swap is two renames, and
power lost between them leaves the plugin missing with the old copy beside it
under `.old` -- worse than nothing happening, better than a version that lies
about which one it is.

Staging is a sibling of the plugin directory rather than a temporary directory
elsewhere: `os.rename` only moves rather than copies within one filesystem, and
a sibling is the only location guaranteed to be on the same one.

The archive reader is asked for when an install starts rather than required at
the top of this file. Every reader loads this module, because the plugin does,
and KOReader drops a plugin whose load raises -- so a `require` up here that
fails on some device costs that reader their highlights and sessions to spare
them an update they were not going to get anyway.
]]

local Network = require("modules/network")
local Signature = require("modules/update/signature")
local TrustedKeys = require("modules/update/keys")
local ffiUtil = require("ffi/util")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")

local UpdateInstaller = {}

-- The most an archive may be. The signature is checked before anything is
-- extracted, so an oversized body cannot run, but it can still exhaust the
-- memory of a device that has very little.
UpdateInstaller.MAX_ARCHIVE_BYTES = 10 * 1024 * 1024

-- A detached Ed25519 signature is 64 bytes; the cap is generous rather than
-- exact so a stray newline is a signature that fails to verify, not a download
-- that fails to arrive.
UpdateInstaller.MAX_SIGNATURE_BYTES = 1024

-- Room demanded before extracting: the archive on disk, plus what it unpacks
-- to, both of which exist at once. The copy being replaced is already on disk
-- and is renamed rather than copied, so it asks for nothing more. Measured
-- against the plugin as it stands, Lua sources compress about three and a half
-- times, so this is that with room to spare rather than a number with nothing
-- behind it.
UpdateInstaller.SPACE_FACTOR = 6

-- What a plugin directory must contain to be one at all. Checked on the staged
-- copy before it replaces anything, so an archive that unpacked to something
-- unrecognisable is discarded rather than installed.
local REQUIRED_FILES = { "main.lua", "_meta.lua" }

-- The two ways this fails. Everything is the first except a signature that was
-- checked and did not match, which is worth saying differently: one means
-- something went wrong, the other means something is wrong.
UpdateInstaller.FAILED = "install_failed"
UpdateInstaller.UNVERIFIED = "install_unverified"

--- Fetch a URL, refusing anything larger than the caller will accept
-- @param url string The address
-- @param max_bytes number The most to accept
-- @return string|nil The body, nil when it did not arrive whole
-- @return string|nil What went wrong
local function fetch(url, max_bytes)
	local code, body, err = Network.request({
		url = url,
		method = "GET",
		max_bytes = max_bytes,
	})

	if not code then
		return nil, tostring(err)
	end

	if code ~= 200 then
		return nil, "HTTP " .. tostring(code)
	end

	return body, nil
end

--- The archive reader, if this KOReader has one to give
-- KOReader's own modules stay on `package.path` after the plugin is loaded,
-- unlike the plugin's own, so asking for this one late works where asking for
-- a sibling module late would not.
-- @return table|nil The archiver, nil where there is none
local function loadArchiver()
	local ok, lib = pcall(require, "ffi/archiver")

	if not ok then
		logger.warn("Crossbill: no archive reader here:", tostring(lib))
		return nil
	end

	return lib
end

--- Whether a path is a directory
-- @param path string The path
-- @return boolean True when it is
local function isDirectory(path)
	return lfs.attributes(path, "mode") == "directory"
end

--- Throw away a staging directory, if one was made
-- Failure to clean up is logged rather than reported: the install already has
-- its own outcome, and leftover staging is untidy rather than harmful.
-- @param path string The directory
local function discard(path)
	if not isDirectory(path) then
		return
	end

	local ok, err = ffiUtil.purgeDir(path)
	if not ok then
		logger.warn("Crossbill: could not remove", path, tostring(err))
	end
end

--- The directory every entry of the archive sits under, if they all share one
-- An archive that unpacks more than one top-level directory, or none, is not a
-- plugin however well-formed it is otherwise.
-- @param reader table The opened archive
-- @return string|nil The single top-level directory, nil when there is not one
local function archiveRoot(reader)
	local root = nil

	for entry in reader:iterate() do
		local top = entry.path:match("^([^/]+)")
		if not top then
			return nil
		end
		if root and root ~= top then
			return nil
		end
		root = top
	end

	return root
end

--- Unpack the archive into a staging directory
-- Entry paths are rewritten from the archive's own top-level directory to the
-- staging one, so the staged copy is what the plugin directory should become
-- rather than a directory containing it.
-- @param reader table The opened archive
-- @param root string The archive's top-level directory
-- @param staging string Where to unpack to
-- @return boolean True when everything was written
-- @return string|nil What went wrong
local function unpack(reader, root, staging)
	local ok, err = lfs.mkdir(staging)
	if not ok then
		return false, "could not create " .. staging .. ": " .. tostring(err)
	end

	-- Compared as text rather than matched as a pattern: a directory name is
	-- not a pattern, and `crossbill-test.koplugin` read as one means something
	-- else entirely.
	local prefix = root .. "/"

	for entry in reader:iterate() do
		-- The root itself is the staging directory, already made above.
		local relative = entry.path:sub(1, #prefix) == prefix and entry.path:sub(#prefix + 1) or nil
		if relative and relative ~= "" then
			local destination = ffiUtil.joinPath(staging, relative)

			-- A file may arrive before the directory holding it.
			local parent = ffiUtil.dirname(destination)
			if not isDirectory(parent) then
				lfs.mkdir(parent)
			end

			if not reader:extractToPath(entry.path, destination) then
				return false, "could not write " .. relative .. ": " .. tostring(reader.err)
			end
		end
	end

	return true, nil
end

--- Whether a staged directory looks like the plugin it claims to be
-- @param staging string The staged directory
-- @return boolean True when nothing is missing
local function looksLikeThePlugin(staging)
	for _index, name in ipairs(REQUIRED_FILES) do
		if lfs.attributes(ffiUtil.joinPath(staging, name), "mode") ~= "file" then
			logger.warn("Crossbill: the staged update has no", name)
			return false
		end
	end

	return true
end

--- Put the staged copy in the plugin's place
-- Two renames rather than one: a directory cannot be renamed onto another that
-- already exists, so the old copy moves aside first. Between the two there is
-- no plugin directory at all, which is the window this cannot close.
-- @param plugin_dir string The directory being replaced
-- @param staging string The staged replacement
-- @return boolean True when the swap completed
-- @return string|nil What went wrong
local function swap(plugin_dir, staging)
	local retired = plugin_dir .. ".old"

	discard(retired)

	local ok, err = os.rename(plugin_dir, retired)
	if not ok then
		return false, "could not move the old plugin aside: " .. tostring(err)
	end

	ok, err = os.rename(staging, plugin_dir)
	if not ok then
		-- The plugin directory is gone and the staged copy would not take its
		-- place. Put the old one back rather than leave nothing there.
		local restored = os.rename(retired, plugin_dir)
		logger.err("Crossbill: could not install the update:", tostring(err), "restored:", tostring(restored))
		return false, "could not move the update into place: " .. tostring(err)
	end

	ffiUtil.fsyncDirectory(ffiUtil.dirname(plugin_dir))
	discard(retired)

	return true, nil
end

--- Replace the plugin with the release the check found
-- @param plugin_dir string The plugin's own directory, as KOReader loaded it
-- @param result table The check result, carrying download_url and signature_url
-- @return boolean True when the update is installed and awaits a restart
-- @return string|nil Which kind of failure, when it failed
-- @return string|nil What went wrong, for the log rather than the reader
function UpdateInstaller.install(plugin_dir, result)
	if type(plugin_dir) ~= "string" or not isDirectory(plugin_dir) then
		return false, UpdateInstaller.FAILED, "no plugin directory at " .. tostring(plugin_dir)
	end

	result = result or {}
	if type(result.download_url) ~= "string" or type(result.signature_url) ~= "string" then
		return false, UpdateInstaller.FAILED, "the release carries no archive and signature to install"
	end

	-- Refused before anything is downloaded: a device that can never verify or
	-- never unpack should not spend a reader's data finding that out.
	if not Signature.isAvailable() then
		return false, UpdateInstaller.FAILED, "this KOReader cannot verify signatures"
	end

	local archiver = loadArchiver()
	if not archiver then
		return false, UpdateInstaller.FAILED, "this KOReader cannot read archives"
	end

	local archive, err = fetch(result.download_url, UpdateInstaller.MAX_ARCHIVE_BYTES)
	if not archive then
		return false, UpdateInstaller.FAILED, "could not download the update: " .. tostring(err)
	end

	local signature
	signature, err = fetch(result.signature_url, UpdateInstaller.MAX_SIGNATURE_BYTES)
	if not signature then
		return false, UpdateInstaller.FAILED, "could not download the signature: " .. tostring(err)
	end

	if not Signature.verify(archive, signature, TrustedKeys) then
		return false, UpdateInstaller.UNVERIFIED, "the archive is not signed by a trusted key"
	end

	local parent = ffiUtil.dirname(plugin_dir)
	-- Two values, not three: KOReader's `df` reports the filesystem's size and
	-- what is free on it, and stops there. Asking it for a third leaves nil,
	-- which reads as "no answer" and skips the check on every device.
	local _, free = ffiUtil.df(parent)
	local needed = #archive * UpdateInstaller.SPACE_FACTOR
	if free and free < needed then
		return false, UpdateInstaller.FAILED, string.format("needs %d bytes, %d free", needed, free)
	end

	local archive_path = ffiUtil.joinPath(parent, "crossbill-update.zip")
	local staging = plugin_dir .. ".new"

	local ok, detail = UpdateInstaller._apply(plugin_dir, archiver, archive, archive_path, staging)

	os.remove(archive_path)
	if not ok then
		discard(staging)
		return false, UpdateInstaller.FAILED, detail
	end

	return true, nil, nil
end

--- Write the archive out, unpack it and swap it in
-- Split from `install` so every path out of it can be followed by the same
-- cleanup, rather than each failure having to remember its own.
-- @param plugin_dir string The plugin's directory
-- @param archiver table The archive reader, already known to be loadable
-- @param archive string The archive's bytes
-- @param archive_path string Where to write them
-- @param staging string Where to unpack to
-- @return boolean True when the plugin was replaced
-- @return string|nil What went wrong
function UpdateInstaller._apply(plugin_dir, archiver, archive, archive_path, staging)
	discard(staging)

	local handle, err = io.open(archive_path, "wb")
	if not handle then
		return false, "could not write the archive: " .. tostring(err)
	end
	handle:write(archive)
	handle:close()

	local reader = archiver.Reader:new()
	if not reader:open(archive_path) then
		return false, "could not read the archive: " .. tostring(reader.err)
	end

	local root = archiveRoot(reader)
	local expected = ffiUtil.basename(plugin_dir)
	if root ~= expected then
		-- This is what keeps the side-by-side test build from installing the
		-- production plugin over itself, and what stops a renamed plugin
		-- directory from being replaced by something that is not it.
		reader:close()
		return false, string.format("the archive holds %s, not %s", tostring(root), expected)
	end

	local ok, detail = unpack(reader, root, staging)
	reader:close()
	if not ok then
		return false, detail
	end

	if not looksLikeThePlugin(staging) then
		return false, "the unpacked update is not a plugin"
	end

	return swap(plugin_dir, staging)
end

return UpdateInstaller
