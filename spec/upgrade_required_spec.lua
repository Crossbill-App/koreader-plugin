local UpgradeRequired = require("modules/upgrade_required")

local UPDATE_URL = "https://github.com/Crossbill-App/koreader-plugin"

--- The body the server sends with a refusal
-- @param detail table|nil What to put under `detail`, nil to leave it out
-- @return table The decoded body
local function refusalBody(detail)
	return { detail = detail }
end

-- KOReader's decoder maps JSON null to a truthy placeholder rather than to nil.
-- This table stands in for it: truthy, and not a string.
local JSON_NULL = setmetatable({}, {
	__tostring = function()
		return "userdata: 0x55d3a1c0"
	end,
})

local FULL_DETAIL = {
	code = "client_upgrade_required",
	client = "koreader-plugin",
	min_supported_version = "0.13.0",
	received_version = "0.12.0",
	update_url = UPDATE_URL,
}

describe("UpgradeRequired", function()
	describe("fromResponse", function()
		it("recognises the status the server turns a too-old plugin away with", function()
			local err = UpgradeRequired.fromResponse(426, refusalBody(FULL_DETAIL))

			assert.is_true(UpgradeRequired.is(err))
		end)

		it("keeps the versions and the address the server named", function()
			local err = UpgradeRequired.fromResponse(426, refusalBody(FULL_DETAIL))

			assert.are.equal("0.13.0", err.min_supported_version)
			assert.are.equal("0.12.0", err.received_version)
			assert.are.equal(UPDATE_URL, err.update_url)
		end)

		it("leaves every other status alone", function()
			assert.is_nil(UpgradeRequired.fromResponse(200, {}))
			assert.is_nil(UpgradeRequired.fromResponse(404, nil))
			assert.is_nil(UpgradeRequired.fromResponse(500, refusalBody(FULL_DETAIL)))
			assert.is_nil(UpgradeRequired.fromResponse(nil, nil))
		end)

		it("still reports the refusal when no body arrived with it", function()
			-- Being turned away is the fact that matters; the versions only
			-- sharpen the wording.
			local err = UpgradeRequired.fromResponse(426, nil)

			assert.is_true(UpgradeRequired.is(err))
			assert.is_nil(err.min_supported_version)
			assert.is_nil(err.received_version)
			assert.is_nil(err.update_url)
		end)

		it("still reports the refusal when the body says nothing it understands", function()
			assert.is_nil(UpgradeRequired.fromResponse(426, refusalBody("Upgrade required")).received_version)
			assert.is_nil(UpgradeRequired.fromResponse(426, refusalBody(nil)).received_version)
			assert.is_nil(UpgradeRequired.fromResponse(426, { unexpected = true }).received_version)
		end)
	end)

	describe("is", function()
		it("tells the refusal apart from the error strings everything else reports", function()
			assert.is_false(UpgradeRequired.is("Upload failed: 500"))
			assert.is_false(UpgradeRequired.is(nil))
			assert.is_false(UpgradeRequired.is({}))
			assert.is_true(UpgradeRequired.is(UpgradeRequired.new(refusalBody(FULL_DETAIL))))
		end)
	end)

	describe("message", function()
		it("names the version the reader has and the one the server wants", function()
			local message = UpgradeRequired.message(UpgradeRequired.new(refusalBody(FULL_DETAIL)))

			assert.are.equal(
				"Your Crossbill plugin (0.12.0) is too old for this server. "
					.. "Please update to 0.13.0 or newer.\n"
					.. UPDATE_URL,
				message
			)
		end)

		it("falls back to asking for an update when the versions are unknown", function()
			local message = UpgradeRequired.message(UpgradeRequired.new(nil))

			assert.are.equal(
				"Your Crossbill plugin is too old for this server. Please update it.\n" .. UPDATE_URL,
				message
			)
		end)

		it("sends the reader to the plugin's own page when the server named none", function()
			-- The address is the only part of the message a reader can act on,
			-- so it is never left out.
			local err = UpgradeRequired.new(refusalBody({
				min_supported_version = "0.13.0",
				received_version = "0.12.0",
			}))

			assert.is_truthy(UpgradeRequired.message(err):find(UPDATE_URL, 1, true))
		end)

		it("says something even when there is no error at all", function()
			assert.is_string(UpgradeRequired.message(nil))
		end)

		describe("a field the server sent as JSON null", function()
			--- The message for a refusal whose detail carries the given fields
			-- @param detail table What the server put under `detail`
			-- @return string The message a reader would be shown
			local function messageFor(detail)
				return UpgradeRequired.message(UpgradeRequired.new(refusalBody(detail)))
			end

			it("is not the version the reader is told they are running", function()
				-- The server sends `"received_version": null` when it cannot parse
				-- the version claimed, and the stand-in for null is truthy.
				local message = messageFor({
					min_supported_version = "0.13.0",
					received_version = JSON_NULL,
				})

				assert.are.equal(
					"Your Crossbill plugin is too old for this server. Please update it.\n" .. UPDATE_URL,
					message
				)
			end)

			it("is not the version the reader is told to update to", function()
				local message = messageFor({
					min_supported_version = JSON_NULL,
					received_version = "0.12.0",
				})

				assert.are.equal(
					"Your Crossbill plugin is too old for this server. Please update it.\n" .. UPDATE_URL,
					message
				)
			end)

			it("is not the address the reader is sent to", function()
				local message = messageFor({
					min_supported_version = "0.13.0",
					received_version = "0.12.0",
					update_url = JSON_NULL,
				})

				assert.are.equal(
					"Your Crossbill plugin (0.12.0) is too old for this server. "
						.. "Please update to 0.13.0 or newer.\n"
						.. UPDATE_URL,
					message
				)
			end)
		end)
	end)

	describe("the error as it travels through the plugin", function()
		it("prints as its message wherever a string was expected", function()
			-- It rides in the error slot everything else fills with a string, so
			-- a path that logs or appends it must not blow up on a table.
			local err = UpgradeRequired.new(refusalBody(FULL_DETAIL))

			assert.are.equal(UpgradeRequired.message(err), tostring(err))
			assert.are.equal("Sync error: " .. UpgradeRequired.message(err), "Sync error: " .. err)
		end)
	end)
end)
