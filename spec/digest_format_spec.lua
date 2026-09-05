local DigestFormat = require("modules/digest_format")

describe("DigestFormat", function()
	describe("title", function()
		it("names the chapter on its own when it has no parent", function()
			assert.are.equal("Chapter Two", DigestFormat.title({ chapter_name = "Chapter Two" }))
		end)

		it("puts the parent chapter in front of the chapter", function()
			assert.are.equal(
				"Part One › Chapter Two",
				DigestFormat.title({ chapter_name = "Chapter Two", parent_chapter_name = "Part One" })
			)
		end)

		it("ignores an empty parent chapter rather than showing a bare separator", function()
			assert.are.equal(
				"Chapter Two",
				DigestFormat.title({ chapter_name = "Chapter Two", parent_chapter_name = "" })
			)
		end)

		it("falls back to a generic name when the item has no chapter name", function()
			assert.are.equal("Chapter", DigestFormat.title({}))
		end)
	end)

	describe("html", function()
		it("escapes the characters that would otherwise be markup", function()
			assert.are.equal(
				"<p>Marx &amp; Engels &lt;i&gt;wrote&lt;/i&gt;</p>",
				DigestFormat.html({
					summary = "Marx & Engels <i>wrote</i>",
				})
			)
		end)

		it("escapes the ampersand first, so its own entities are not escaped again", function()
			-- Escaping < before & would turn "&lt;" into "&amp;lt;".
			assert.are.equal("<p>a &lt; b &amp; c &gt; d</p>", DigestFormat.html({ summary = "a < b & c > d" }))
		end)

		it("renders inline markdown as tags", function()
			assert.are.equal(
				"<p><strong>bold</strong> <strong>also</strong> <em>italic</em> <code>code</code></p>",
				DigestFormat.html({ summary = "**bold** __also__ *italic* `code`" })
			)
		end)

		it("splits the summary into a paragraph per blank line", function()
			assert.are.equal("<p>First.</p>\n<p>Second.</p>", DigestFormat.html({ summary = "First.\n\nSecond." }))
		end)

		it("keeps the last paragraph, which has no blank line after it", function()
			-- The renderer appends one so the final paragraph matches too.
			assert.are.equal("<p>Only one.</p>", DigestFormat.html({ summary = "Only one." }))
		end)

		it("renders key points as an unordered list", function()
			assert.are.equal(
				"<h2>Key points</h2>\n<ul><li>One</li><li>Two</li></ul>",
				DigestFormat.html({ keypoints = { "One", "Two" } })
			)
		end)

		it("renders questions as an ordered list", function()
			assert.are.equal(
				"<h2>Questions to think about</h2>\n<ol><li>Why?</li></ol>",
				DigestFormat.html({ questions = { "Why?" } })
			)
		end)

		it("says there is nothing to show when the item is empty", function()
			assert.are.equal("<p>No digest available for this chapter.</p>", DigestFormat.html({}))
		end)
	end)

	describe("plainText", function()
		it("strips the markdown markers an older viewer would show literally", function()
			assert.are.equal(
				"bold also italic code",
				DigestFormat.plainText({ summary = "**bold** __also__ *italic* `code`" })
			)
		end)

		it("strips heading markers at the start of any line", function()
			assert.are.equal("Title\nBody", DigestFormat.plainText({ summary = "## Title\n### Body" }))
		end)

		it("bullets the key points under their heading", function()
			assert.are.equal("Key points\n• One\n• Two", DigestFormat.plainText({ keypoints = { "One", "Two" } }))
		end)

		it("numbers the questions under their heading", function()
			assert.are.equal(
				"Questions to think about\n1. Why?\n2. How?",
				DigestFormat.plainText({ questions = { "Why?", "How?" } })
			)
		end)

		it("separates the sections it has by a blank line", function()
			assert.are.equal(
				"A summary.\n\nKey points\n• One",
				DigestFormat.plainText({ summary = "A summary.", keypoints = { "One" } })
			)
		end)

		it("says there is nothing to show when the item is empty", function()
			assert.are.equal("No digest available for this chapter.", DigestFormat.plainText({}))
		end)
	end)
end)
