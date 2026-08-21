--[[
Title Matching Module for Crossbill Sync

Chapter titles reach the plugin from two directions — the device's table of
contents and the server's chapter list — and both the highlight extractor and
the digest service compare them. The comparison has to agree with the server's
own, so the rule lives here once rather than in a copy per caller.
]]

local TitleMatch = {}

--- Normalize a title for comparison: trim, collapse internal whitespace, lowercase
-- Non-string input (including JSON null sentinels) normalizes to nil.
-- @param title string|nil The raw title
-- @return string|nil The normalized title, or nil for nil/non-string input
function TitleMatch.normalize(title)
	if type(title) ~= "string" then
		return nil
	end
	-- Collapse all runs of whitespace to single spaces
	local text = title:gsub("%s+", " ")
	-- Trim leading/trailing whitespace
	text = text:gsub("^%s*(.-)%s*$", "%1")
	return text:lower()
end

return TitleMatch
