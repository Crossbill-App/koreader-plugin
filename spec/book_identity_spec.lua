local BookIdentity = require("modules/book_identity")

-- One fixture book, and the copy of it living at another path. The hashes are
-- what `ffi/sha2`'s stand-in makes of the strings the module hands it, so the
-- assertions below pin the exact formula rather than a hex digest.
local TITLE = "Dune"
local AUTHOR = "Frank Herbert"
local BOOK_PATH = "/books/dune.epub"

describe("BookIdentity", function()
	describe("clientBookId", function()
		it("hashes the title and author, joined by a pipe", function()
			assert.are.equal("md5:Dune|Frank Herbert", BookIdentity.clientBookId(TITLE, AUTHOR))
		end)

		it("tells two books by one author apart", function()
			assert.are_not.equal(
				BookIdentity.clientBookId(TITLE, AUTHOR),
				BookIdentity.clientBookId("Dune Messiah", AUTHOR)
			)
		end)

		it("stands an author-less book in for the empty author", function()
			assert.are.equal("md5:Dune|", BookIdentity.clientBookId(TITLE, nil))
		end)
	end)

	describe("fileHash", function()
		it("hashes the path verbatim", function()
			assert.are.equal("md5:/books/dune.epub", BookIdentity.fileHash(BOOK_PATH))
		end)

		it("tells one copy of a book from another", function()
			assert.are_not.equal(BookIdentity.fileHash(BOOK_PATH), BookIdentity.fileHash("/books/copies/dune.epub"))
		end)

		it("has no answer for a missing path", function()
			assert.is_nil(BookIdentity.fileHash(nil))
			assert.is_nil(BookIdentity.fileHash(""))
		end)
	end)
end)
