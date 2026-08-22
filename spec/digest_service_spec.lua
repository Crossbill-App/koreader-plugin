local UpgradeRequired = require("modules/upgrade_required")

-- `modules/digest_service` asks `modules/network` whether the device is online.
-- That is the plugin's own module rather than one of KOReader's, so it cannot be
-- shadowed from spec/support: seeding the package cache before requiring the
-- service keeps the socket layer out of the run (see spec/api_client_spec.lua).
-- Offline unless a spec says otherwise.
local NetworkFake = { connected = false }
NetworkFake.isConnected = function()
	return NetworkFake.connected
end

local real_network = package.loaded["modules/network"]
package.loaded["modules/network"] = NetworkFake
local DigestService = require("modules/digest_service")
package.loaded["modules/network"] = real_network

local CLIENT_BOOK_ID = "b9c1"

describe("DigestService", function()
	describe("a server that turns this plugin away as too old", function()
		local REFUSAL = UpgradeRequired.fromResponse(426, {
			detail = {
				code = "client_upgrade_required",
				client = "koreader-plugin",
				min_supported_version = "0.13.0",
				received_version = "0.12.0",
				update_url = "https://github.com/Crossbill-App/koreader-plugin",
			},
		})

		--- Build a service whose server answers the digest fetch with the tuple
		-- @param code number|nil The HTTP status
		-- @param err any The error the api client reports
		-- @return table The DigestService instance
		local function serviceAnswering(code, err)
			return DigestService:new({
				getBookDigest = function()
					return code, nil, err
				end,
			}, {
				hasBook = function()
					return false
				end,
			})
		end

		it("reports a refused refresh as the refusal it was", function()
			local ok, err_kind, err = serviceAnswering(426, REFUSAL):refreshBook(CLIENT_BOOK_ID)

			assert.is_false(ok)
			assert.are.equal(UpgradeRequired.KIND, err_kind)
			assert.are.equal(REFUSAL, err)
		end)

		it("passes the refusal on to whoever opened the chapter's digest", function()
			-- Reported as a missing cache, this would tell the reader to sync
			-- while online, which is exactly what cannot help.
			local item, err_kind, err = serviceAnswering(426, REFUSAL):getForCurrentChapter({}, CLIENT_BOOK_ID)

			assert.is_nil(item)
			assert.are.equal(UpgradeRequired.KIND, err_kind)
			assert.are.equal(REFUSAL, err)
		end)

		it("still reports an ordinary failed fetch as a cache it could not fill", function()
			local item, err_kind, err =
				serviceAnswering(500, "server exploded"):getForCurrentChapter({}, CLIENT_BOOK_ID)

			assert.is_nil(item)
			assert.are.equal("no_cache", err_kind)
			assert.is_nil(err)
		end)

		describe("a book cached back when it had no digests", function()
			-- Opening the popup re-checks the server when a book's empty cache is
			-- older than the re-fetch window.
			local BEYOND_THE_REFETCH_WINDOW = 1000

			before_each(function()
				NetworkFake.connected = true
			end)

			after_each(function()
				NetworkFake.connected = false
			end)

			--- Build a service holding a stale, empty cache for the book
			-- @param code number|nil The HTTP status the re-fetch is answered with
			-- @param err any The error the api client reports
			-- @return table The DigestService instance
			local function serviceRefetching(code, err)
				return DigestService:new({
					getBookDigest = function()
						return code, nil, err
					end,
				}, {
					hasBook = function()
						return true
					end,
					getBook = function()
						return {}
					end,
					getFetchedAt = function()
						return os.time() - BEYOND_THE_REFETCH_WINDOW
					end,
				})
			end

			it("passes on the refusal the re-fetch met", function()
				-- Reported as an empty book, this would send the reader off to
				-- generate a digest that may well already exist.
				local item, err_kind, err = serviceRefetching(426, REFUSAL):getForCurrentChapter({}, CLIENT_BOOK_ID)

				assert.is_nil(item)
				assert.are.equal(UpgradeRequired.KIND, err_kind)
				assert.are.equal(REFUSAL, err)
			end)

			it("still reports an ordinary failed re-fetch as a book without a digest", function()
				local item, err_kind, err =
					serviceRefetching(500, "server exploded"):getForCurrentChapter({}, CLIENT_BOOK_ID)

				assert.is_nil(item)
				assert.are.equal("no_digest_for_book", err_kind)
				assert.is_nil(err)
			end)
		end)
	end)
end)
