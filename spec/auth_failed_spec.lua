local AuthFailed = require("modules/auth_failed")

describe("AuthFailed", function()
	describe("is", function()
		it("tells the failure apart from the error strings everything else reports", function()
			-- The whole point of the type: "Login failed: 401" as a string is a
			-- network or server error that happens to read like an auth failure,
			-- and must not open the authentication dialog.
			assert.is_false(AuthFailed.is("Login failed: 401"))
			assert.is_false(AuthFailed.is(nil))
			assert.is_false(AuthFailed.is({}))
			assert.is_true(AuthFailed.is(AuthFailed.new("Login failed: 401")))
		end)
	end)

	describe("message", function()
		it("hands back the message the failure was built with", function()
			assert.are.equal(
				"Username or password not configured",
				AuthFailed.message(AuthFailed.new("Username or password not configured"))
			)
		end)

		it("says something even when there is no error at all", function()
			assert.are.equal("unknown error", AuthFailed.message(nil))
		end)

		it("says something for a failure that carries no message", function()
			assert.are.equal("unknown error", AuthFailed.message(AuthFailed.new(nil)))
		end)

		it("names an error of any other kind as it stands", function()
			-- The dialog is only reached for an AuthFailed, but nothing stops a
			-- caller passing something else, and a message is worth more than a
			-- crash.
			assert.are.equal("Connection refused", AuthFailed.message("Connection refused"))
		end)
	end)

	describe("the error as it travels through the plugin", function()
		it("prints as its message wherever a string was expected", function()
			-- It rides in the error slot everything else fills with a string, so
			-- a path that logs or appends it must not blow up on a table.
			local err = AuthFailed.new("Refresh failed: 401")

			assert.are.equal("Refresh failed: 401", tostring(err))
			assert.are.equal("Sync failed: Refresh failed: 401", "Sync failed: " .. err)
			assert.are.equal("Refresh failed: 401 (auth)", err .. " (auth)")
		end)
	end)
end)
