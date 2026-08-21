local TitleMatch = require("modules/title_match")

describe("TitleMatch", function()
	describe("normalize", function()
		it("lowercases the title", function()
			assert.are.equal("chapter one", TitleMatch.normalize("Chapter One"))
		end)

		it("trims the ends", function()
			assert.are.equal("chapter one", TitleMatch.normalize("  Chapter One\n"))
		end)

		it("collapses runs of whitespace, newlines and tabs included", function()
			assert.are.equal("chapter one", TitleMatch.normalize("Chapter \t\n one"))
		end)

		it("matches titles that differ only in spacing and case", function()
			-- The device's ToC and the server's chapter list are typed by
			-- different tools; this is the difference they are allowed to have.
			assert.are.equal(TitleMatch.normalize("THE  SPICE"), TitleMatch.normalize("the spice "))
		end)

		it("normalizes a whitespace-only title to an empty string", function()
			assert.are.equal("", TitleMatch.normalize("   "))
		end)

		it("returns nil for a missing title", function()
			assert.is_nil(TitleMatch.normalize(nil))
		end)

		it("returns nil for a JSON null sentinel, which is not a string", function()
			assert.is_nil(TitleMatch.normalize({}))
		end)
	end)
end)
