--[[
Book Identity Module for Crossbill Sync

The two hashes a book is known by, in one place:

- the client book id, `md5("title|author")`, which every copy of a book shares
  and the server deduplicates books by
- the file hash, `md5(path)`, which tells one reader's copy of a book from
  another's and keys the local session and snapshot records

They live together because separate copies of either formula have to agree
byte for byte -- the snapshot ledger decides whose highlights it is looking at
by comparing file hashes -- and a comment promising two functions match is not
something anything can enforce.
]]

local Log = require("modules/log")
local log = Log.forModule("BookIdentity")
local md5 = require("ffi/sha2").md5

local BookIdentity = {}

--- Identify a book by its title and author
-- Stable across copies and devices: the server deduplicates books by this.
-- @param title string|nil Book title
-- @param author string|nil Book author
-- @return string MD5 hash of "title|author"
function BookIdentity.clientBookId(title, author)
	local input = (title or "") .. "|" .. (author or "")
	return md5(input)
end

--- Identify one copy of a book by the file it is read from
-- Sessions are recorded against this hash, and the snapshot ledger tells the
-- copy it pulled into from any other copy by it.
-- @param path string|nil The document's file path
-- @return string|nil MD5 hash of the path, nil when there is no path to hash
function BookIdentity.fileHash(path)
	if type(path) ~= "string" or path == "" then
		-- Without an identity nothing may be diffed or flagged against the
		-- ledger, and a pull records the book as owned by no file.
		log.warn("No document path to identify the book's file by")
		return nil
	end

	return md5(path)
end

return BookIdentity
