local PluginIdentity = require("modules/plugin_identity")

describe("PluginIdentity", function()
	-- Everything below is pinned as a literal on purpose. These strings are on
	-- readers' devices already -- as a settings key, a database filename and
	-- two gesture bindings -- and a derivation that changes any of them by a
	-- byte loses that reader's configuration and history with no error to say
	-- so. Asserting them against the derivation that produced them would agree
	-- with any mistake; the literals are the fixed point.
	describe("for the production name", function()
		local identity = PluginIdentity.derive("Crossbill")

		it("keeps the name as the display name", function()
			assert.are.equal("Crossbill", identity.display_name)
		end)

		it("derives the namespace readers' settings are keyed by", function()
			assert.are.equal("crossbill", identity.namespace)
			assert.are.equal("crossbill_sync", identity.namespace .. "_sync")
		end)

		it("derives the filename of the database readers' history lives in", function()
			assert.are.equal("crossbill.sqlite3", identity.database_filename)
		end)

		it("derives the dispatcher action ids readers' gestures are bound to", function()
			assert.are.equal("crossbill_sync_current_book", identity.namespace .. "_sync_current_book")
			-- Still "summary" rather than "digest": see the comment in
			-- main.lua's onDispatcherRegisterActions.
			assert.are.equal("crossbill_show_chapter_summary", identity.namespace .. "_show_chapter_summary")
		end)

		it("derives the event prefix the handlers are named after", function()
			assert.are.equal("Crossbill", identity.event_prefix)
			assert.are.equal("CrossbillSyncCurrentBook", identity.event_prefix .. "SyncCurrentBook")
			assert.are.equal("CrossbillShowChapterDigest", identity.event_prefix .. "ShowChapterDigest")
		end)
	end)

	describe("for the side-by-side test name", function()
		local identity = PluginIdentity.derive("Crossbill Test")

		it("keeps the name as the display name", function()
			assert.are.equal("Crossbill Test", identity.display_name)
		end)

		it("turns the space into an underscore for the namespace", function()
			assert.are.equal("crossbill_test", identity.namespace)
			assert.are.equal("crossbill_test.sqlite3", identity.database_filename)
		end)

		it("closes the space up and keeps the case for the event prefix", function()
			assert.are.equal("CrossbillTest", identity.event_prefix)
		end)

		it("shares nothing with the production plugin", function()
			local production = PluginIdentity.derive("Crossbill")
			assert.are_not.equal(production.namespace, identity.namespace)
			assert.are_not.equal(production.database_filename, identity.database_filename)
			assert.are_not.equal(production.event_prefix, identity.event_prefix)
		end)
	end)

	it("derives the running plugin's own identity from _meta", function()
		local meta = require("_meta")
		assert.are.same(PluginIdentity.derive(meta.name), {
			display_name = PluginIdentity.display_name,
			namespace = PluginIdentity.namespace,
			database_filename = PluginIdentity.database_filename,
			event_prefix = PluginIdentity.event_prefix,
		})
	end)

	it("collapses runs of whitespace rather than leaving them", function()
		local identity = PluginIdentity.derive("Two  Words Here")
		assert.are.equal("two_words_here", identity.namespace)
		assert.are.equal("TwoWordsHere", identity.event_prefix)
	end)
end)
