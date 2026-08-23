--[[
The installer is the only code in the plugin that removes anything, so it is
tested against real directories rather than mocks: every spec here builds a real
plugin directory in a temporary place, runs a real install over it, and looks at
what is actually on disk afterwards. A swap with its arguments the wrong way
round passes a mock and destroys a reader's plugin.

`modules/network` and `modules/update/signature` are faked, since one opens
sockets and the other needs a LibreSSL that is not here. Everything else -- the
staging, the renames, the recursive delete -- is the real thing.
]]

local lfs = require("lfs")
local Archiver = require("ffi/archiver")
local ffiUtil = require("ffi/util")

local NetworkFake = { bodies = {}, requests = {} }

--- Answer a request with whatever the current test put at that URL
-- @param options table The request the installer built
-- @return number|nil, string, string|nil The status, body and error
function NetworkFake.request(options)
	table.insert(NetworkFake.requests, options)
	local answer = NetworkFake.bodies[options.url]

	if not answer then
		return nil, "", "no route to " .. tostring(options.url)
	end

	if answer.code ~= 200 then
		return answer.code, "", nil
	end

	return 200, answer.body, nil
end

local SignatureFake = { available = true, verifies = true, calls = {} }

--- Whether verification is possible, as the current test decided
function SignatureFake.isAvailable()
	return SignatureFake.available
end

--- Whether the archive verifies, as the current test decided
-- @param data string The bytes that were signed
-- @param signature string The detached signature
-- @return boolean The queued answer
function SignatureFake.verify(data, signature)
	table.insert(SignatureFake.calls, { data = data, signature = signature })
	return SignatureFake.verifies
end

local saved = {}
for name, fake in pairs({
	["modules/network"] = NetworkFake,
	["modules/update/signature"] = SignatureFake,
}) do
	saved[name] = package.loaded[name]
	package.loaded[name] = fake
end
saved["modules/update/installer"] = package.loaded["modules/update/installer"]
local UpdateInstaller = require("modules/update/installer")
for name in pairs(saved) do
	package.loaded[name] = saved[name]
end

local ARCHIVE_URL = "https://example.test/crossbill.koplugin.zip"
local SIGNATURE_URL = ARCHIVE_URL .. ".sig"
local RESULT = { download_url = ARCHIVE_URL, signature_url = SIGNATURE_URL }

-- What the archive weighs, which is all the room check has to go on
local ARCHIVE_BODY = "PK-archive-bytes"

describe("UpdateInstaller.install", function()
	local root, plugin_dir

	--- The contents of a file, or nil when there is no such file
	-- @param path string The file
	-- @return string|nil The contents
	local function read(path)
		local handle = io.open(path, "rb")
		if not handle then
			return nil
		end
		local contents = handle:read("*a")
		handle:close()
		return contents
	end

	--- Write a file, creating nothing else
	-- @param path string The file
	-- @param contents string What to put in it
	local function write(path, contents)
		local handle = assert(io.open(path, "wb"))
		handle:write(contents)
		handle:close()
	end

	--- Build a plugin directory that looks like an installed one
	-- @param name string The directory's name
	-- @param version string What its _meta.lua should claim
	-- @return string The directory
	local function installedPlugin(name, version)
		local dir = ffiUtil.joinPath(root, name)
		assert(lfs.mkdir(dir))
		assert(lfs.mkdir(ffiUtil.joinPath(dir, "modules")))
		write(ffiUtil.joinPath(dir, "main.lua"), "-- old main")
		write(ffiUtil.joinPath(dir, "_meta.lua"), 'return { version = "' .. version .. '" }')
		write(ffiUtil.joinPath(ffiUtil.joinPath(dir, "modules"), "old_only.lua"), "-- gone in the new version")
		return dir
	end

	--- Describe the archive the next install will download
	-- @param entries table|nil Entries to use instead of a normal new version
	local function archiveHolding(entries)
		Archiver.setEntries(entries or {
			{ path = "crossbill.koplugin", mode = "directory" },
			{ path = "crossbill.koplugin/main.lua", mode = "file", content = "-- new main" },
			{
				path = "crossbill.koplugin/_meta.lua",
				mode = "file",
				content = 'return { version = "0.14.0" }',
			},
			{ path = "crossbill.koplugin/modules", mode = "directory" },
			{
				path = "crossbill.koplugin/modules/new_only.lua",
				mode = "file",
				content = "-- only in the new version",
			},
		})
	end

	--- Run something with `ffi/archiver` out of reach
	-- What an older KOReader, or one whose libarchive will not load, looks
	-- like. The module is unloaded and a loader that raises is put in front of
	-- the real one, so `require` fails the way it would there.
	-- @param body function What to run while it cannot be loaded
	local function withoutArchiver(body)
		local loaded = package.loaded["ffi/archiver"]
		package.loaded["ffi/archiver"] = nil
		table.insert(package.loaders, 1, function(name)
			if name == "ffi/archiver" then
				return function()
					error("no libarchive here")
				end
			end
		end)

		local ok, err = pcall(body)

		table.remove(package.loaders, 1)
		package.loaded["ffi/archiver"] = loaded

		if not ok then
			error(err, 0)
		end
	end

	before_each(function()
		root = os.tmpname()
		os.remove(root)
		assert(lfs.mkdir(root))
		plugin_dir = installedPlugin("crossbill.koplugin", "0.13.0")

		NetworkFake.requests = {}
		NetworkFake.bodies = {
			[ARCHIVE_URL] = { code = 200, body = ARCHIVE_BODY },
			[SIGNATURE_URL] = { code = 200, body = string.rep("s", 64) },
		}
		SignatureFake.available = true
		SignatureFake.verifies = true
		SignatureFake.calls = {}
		Archiver.failOpenWith(nil)
		archiveHolding()
		ffiUtil.setFreeSpace(1024 * 1024 * 1024)
	end)

	after_each(function()
		if root and lfs.attributes(root, "mode") == "directory" then
			ffiUtil.purgeDir(root)
		end
	end)

	describe("a signed update", function()
		it("replaces the plugin with the new version", function()
			local ok, kind, detail = UpdateInstaller.install(plugin_dir, RESULT)

			assert.is_true(ok, tostring(detail))
			assert.is_nil(kind)
			assert.are.equal("-- new main", read(ffiUtil.joinPath(plugin_dir, "main.lua")))
			assert.are.equal("-- only in the new version", read(ffiUtil.joinPath(plugin_dir, "modules/new_only.lua")))
		end)

		it("does not leave the old version's files behind", function()
			-- A file dropped between releases must go, which is the whole
			-- reason the directory is replaced rather than written over.
			UpdateInstaller.install(plugin_dir, RESULT)

			assert.is_nil(read(ffiUtil.joinPath(plugin_dir, "modules/old_only.lua")))
		end)

		it("leaves nothing beside the plugin afterwards", function()
			UpdateInstaller.install(plugin_dir, RESULT)

			local left = {}
			for entry in lfs.dir(root) do
				if entry ~= "." and entry ~= ".." then
					table.insert(left, entry)
				end
			end

			assert.are.same({ "crossbill.koplugin" }, left)
		end)

		it("verifies the bytes it downloaded, not something else", function()
			UpdateInstaller.install(plugin_dir, RESULT)

			assert.are.equal(1, #SignatureFake.calls)
			assert.are.equal(ARCHIVE_BODY, SignatureFake.calls[1].data)
			assert.are.equal(string.rep("s", 64), SignatureFake.calls[1].signature)
		end)

		it("caps what it will download", function()
			UpdateInstaller.install(plugin_dir, RESULT)

			assert.are.equal(UpdateInstaller.MAX_ARCHIVE_BYTES, NetworkFake.requests[1].max_bytes)
			assert.are.equal(UpdateInstaller.MAX_SIGNATURE_BYTES, NetworkFake.requests[2].max_bytes)
		end)
	end)

	describe("an update it will not trust", function()
		it("refuses one whose signature does not match, and says so distinctly", function()
			SignatureFake.verifies = false

			local ok, kind = UpdateInstaller.install(plugin_dir, RESULT)

			assert.is_false(ok)
			assert.are.equal(UpdateInstaller.UNVERIFIED, kind)
			assert.are.equal("-- old main", read(ffiUtil.joinPath(plugin_dir, "main.lua")))
		end)

		it("refuses when it cannot verify at all, before downloading anything", function()
			SignatureFake.available = false

			local ok, kind = UpdateInstaller.install(plugin_dir, RESULT)

			assert.is_false(ok)
			assert.are.equal(UpdateInstaller.FAILED, kind)
			assert.are.equal(0, #NetworkFake.requests)
		end)

		it("refuses when it cannot unpack anything, before downloading anything", function()
			-- The plugin still loads on a KOReader with no archive reader; it
			-- is the update that is refused, not everything else the plugin
			-- does, which is why this module asks for the reader here rather
			-- than at the top of the file.
			withoutArchiver(function()
				local ok, kind = UpdateInstaller.install(plugin_dir, RESULT)

				assert.is_false(ok)
				assert.are.equal(UpdateInstaller.FAILED, kind)
				assert.are.equal(0, #NetworkFake.requests)
			end)
		end)

		it("refuses a release with no signature attached", function()
			local ok, kind = UpdateInstaller.install(plugin_dir, { download_url = ARCHIVE_URL })

			assert.is_false(ok)
			assert.are.equal(UpdateInstaller.FAILED, kind)
			assert.are.equal(0, #NetworkFake.requests)
		end)

		it("refuses a release with no archive attached", function()
			local ok, kind = UpdateInstaller.install(plugin_dir, { signature_url = SIGNATURE_URL })

			assert.is_false(ok)
			assert.are.equal(UpdateInstaller.FAILED, kind)
		end)
	end)

	describe("an archive that is not this plugin", function()
		it("refuses to install the production plugin over the test build", function()
			-- The test build is a renamed copy, and the published archive
			-- always unpacks to crossbill.koplugin.
			local test_dir = installedPlugin("crossbill-test.koplugin", "0.13.0")

			local ok, kind = UpdateInstaller.install(test_dir, RESULT)

			assert.is_false(ok)
			assert.are.equal(UpdateInstaller.FAILED, kind)
			assert.are.equal("-- old main", read(ffiUtil.joinPath(test_dir, "main.lua")))
		end)

		it("refuses an archive with more than one top-level directory", function()
			archiveHolding({
				{ path = "crossbill.koplugin", mode = "directory" },
				{ path = "crossbill.koplugin/main.lua", mode = "file", content = "-- new" },
				{ path = "somethingelse/evil.lua", mode = "file", content = "-- no" },
			})

			local ok, kind = UpdateInstaller.install(plugin_dir, RESULT)

			assert.is_false(ok)
			assert.are.equal(UpdateInstaller.FAILED, kind)
			assert.are.equal("-- old main", read(ffiUtil.joinPath(plugin_dir, "main.lua")))
		end)

		it("refuses an archive that unpacks to no main.lua", function()
			archiveHolding({
				{ path = "crossbill.koplugin", mode = "directory" },
				{ path = "crossbill.koplugin/_meta.lua", mode = "file", content = "return {}" },
			})

			local ok, kind = UpdateInstaller.install(plugin_dir, RESULT)

			assert.is_false(ok)
			assert.are.equal(UpdateInstaller.FAILED, kind)
			assert.are.equal("-- old main", read(ffiUtil.joinPath(plugin_dir, "main.lua")))
		end)

		it("refuses an archive that will not open", function()
			Archiver.failOpenWith("truncated")

			local ok, kind = UpdateInstaller.install(plugin_dir, RESULT)

			assert.is_false(ok)
			assert.are.equal(UpdateInstaller.FAILED, kind)
			assert.are.equal("-- old main", read(ffiUtil.joinPath(plugin_dir, "main.lua")))
		end)
	end)

	describe("when it cannot get what it needs", function()
		it("refuses when the archive will not download", function()
			NetworkFake.bodies[ARCHIVE_URL] = { code = 404 }

			local ok, kind = UpdateInstaller.install(plugin_dir, RESULT)

			assert.is_false(ok)
			assert.are.equal(UpdateInstaller.FAILED, kind)
			assert.are.equal(0, #SignatureFake.calls)
		end)

		it("refuses when the signature will not download", function()
			NetworkFake.bodies[SIGNATURE_URL] = nil

			local ok, kind = UpdateInstaller.install(plugin_dir, RESULT)

			assert.is_false(ok)
			assert.are.equal(UpdateInstaller.FAILED, kind)
			assert.are.equal(0, #SignatureFake.calls)
		end)

		it("refuses when the device has no room", function()
			ffiUtil.setFreeSpace(#ARCHIVE_BODY * UpdateInstaller.SPACE_FACTOR - 1)

			local ok, kind = UpdateInstaller.install(plugin_dir, RESULT)

			assert.is_false(ok)
			assert.are.equal(UpdateInstaller.FAILED, kind)
			assert.are.equal("-- old main", read(ffiUtil.joinPath(plugin_dir, "main.lua")))
		end)

		it("installs when there is just enough room", function()
			-- The other side of the same boundary: a check that reads the wrong
			-- value from `df` passes the refusal above by refusing nothing.
			ffiUtil.setFreeSpace(#ARCHIVE_BODY * UpdateInstaller.SPACE_FACTOR)

			local ok, kind, detail = UpdateInstaller.install(plugin_dir, RESULT)

			assert.is_true(ok, tostring(kind) .. " " .. tostring(detail))
			assert.are.equal("-- new main", read(ffiUtil.joinPath(plugin_dir, "main.lua")))
		end)

		it("refuses when there is no plugin directory to replace", function()
			local ok, kind = UpdateInstaller.install(ffiUtil.joinPath(root, "not-there"), RESULT)

			assert.is_false(ok)
			assert.are.equal(UpdateInstaller.FAILED, kind)
		end)
	end)

	describe("cleaning up after itself", function()
		it("leaves no staging behind when the install fails", function()
			archiveHolding({
				{ path = "crossbill.koplugin", mode = "directory" },
				{ path = "crossbill.koplugin/_meta.lua", mode = "file", content = "return {}" },
			})

			UpdateInstaller.install(plugin_dir, RESULT)

			assert.is_nil(lfs.attributes(plugin_dir .. ".new", "mode"))
			assert.is_nil(lfs.attributes(plugin_dir .. ".old", "mode"))
		end)

		it("starts from a clean slate when staging was left from before", function()
			-- A previous run killed part-way through leaves this behind, and it
			-- must not be mistaken for the update being installed now.
			local stale = plugin_dir .. ".new"
			assert(lfs.mkdir(stale))
			write(ffiUtil.joinPath(stale, "main.lua"), "-- stale")

			local ok = UpdateInstaller.install(plugin_dir, RESULT)

			assert.is_true(ok)
			assert.are.equal("-- new main", read(ffiUtil.joinPath(plugin_dir, "main.lua")))
		end)

		it("removes the downloaded archive whether it worked or not", function()
			SignatureFake.verifies = false
			UpdateInstaller.install(plugin_dir, RESULT)
			assert.is_nil(lfs.attributes(ffiUtil.joinPath(root, "crossbill-update.zip"), "mode"))

			SignatureFake.verifies = true
			UpdateInstaller.install(plugin_dir, RESULT)
			assert.is_nil(lfs.attributes(ffiUtil.joinPath(root, "crossbill-update.zip"), "mode"))
		end)
	end)
	describe("a plugin directory whose name is not a pattern", function()
		it("installs an archive whose root contains a hyphen and a dot", function()
			-- Read as a Lua pattern, "crossbill-test.koplugin" means something
			-- else, and every entry would be skipped as not being under it.
			local test_dir = installedPlugin("crossbill-test.koplugin", "0.13.0")
			archiveHolding({
				{ path = "crossbill-test.koplugin", mode = "directory" },
				{ path = "crossbill-test.koplugin/main.lua", mode = "file", content = "-- new test main" },
				{ path = "crossbill-test.koplugin/_meta.lua", mode = "file", content = "return {}" },
			})

			local ok, kind, detail = UpdateInstaller.install(test_dir, RESULT)

			assert.is_true(ok, tostring(detail))
			assert.is_nil(kind)
			assert.are.equal("-- new test main", read(ffiUtil.joinPath(test_dir, "main.lua")))
		end)
	end)
end)
