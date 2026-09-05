local UpgradeRequired = require("modules/upgrade_required")
local FakeNetwork = require("fake_network")

-- `modules/digest_service` asks `modules/network` whether the device is online.
-- That is the plugin's own module rather than one of KOReader's, so it cannot be
-- shadowed from spec/support: seeding the package cache before requiring the
-- service keeps the socket layer out of the run (see spec/api_client_spec.lua).
-- Offline unless a spec says otherwise.
local network = FakeNetwork:new()

local real_network = package.loaded["modules/network"]
package.loaded["modules/network"] = network
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

		--- Build a service whose digest fetch raises rather than answering
		-- @param err any What the api client raises
		-- @return table The DigestService instance
		local function serviceRaising(err)
			return DigestService:new({
				getBookDigest = function()
					error(err, 0)
				end,
			}, {
				hasBook = function()
					return false
				end,
			})
		end

		it("lets a refused refresh raise rather than reporting it as a kind", function()
			-- A refresh runs inside a sync, which catches the refusal for the
			-- whole attempt; there is nothing for this to add.
			local service = serviceRaising(REFUSAL)

			local ok, err = pcall(function()
				return service:refreshBook(CLIENT_BOOK_ID)
			end)

			assert.is_false(ok)
			assert.are.equal(REFUSAL, err)
		end)

		it("passes the refusal on to whoever opened the chapter's digest", function()
			-- Opened from an event handler, with no sync around it to catch the
			-- raise. Reported as a missing cache, this would tell the reader to
			-- sync while online, which is exactly what cannot help.
			local item, err_kind, err = serviceRaising(REFUSAL):getForCurrentChapter({}, CLIENT_BOOK_ID)

			assert.is_nil(item)
			assert.are.equal(UpgradeRequired.KIND, err_kind)
			assert.are.equal(REFUSAL, err)
		end)

		it("lets any other error out of the chapter's digest as it was raised", function()
			-- Only the refusal is this module's to answer for; the rest is the
			-- reader's event handler to fail on, as it always was.
			local service = serviceRaising("socket closed")

			local ok, err = pcall(function()
				return service:getForCurrentChapter({}, CLIENT_BOOK_ID)
			end)

			assert.is_false(ok)
			assert.are.equal("socket closed", err)
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
				network.connected = true
			end)

			after_each(function()
				network.connected = false
			end)

			--- Build a service holding a stale, empty cache for the book
			-- @param code number|nil The HTTP status the re-fetch is answered
			--   with, nil to raise `err` instead
			-- @param err any The error the api client reports or raises
			-- @return table The DigestService instance
			local function serviceRefetching(code, err)
				return DigestService:new({
					getBookDigest = function()
						if not code then
							error(err, 0)
						end
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
				local item, err_kind, err = serviceRefetching(nil, REFUSAL):getForCurrentChapter({}, CLIENT_BOOK_ID)

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
