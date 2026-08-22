--[[
Digest Service Module for Crossbill Sync

UI-free logic that fetches, caches and resolves per-chapter digests.
Given the current reading position it matches the current chapter against the
cached digest items using a small, staged matching algorithm.

Public API:
  DigestService:new(api_client, digest_cache)
  DigestService:refreshBook(client_book_id) -> ok, err_kind, err
  DigestService:getForCurrentChapter(ui, client_book_id) -> item, err_kind, err

err_kind is one of:
  nil                      matched, item returned
  "no_cache"               nothing cached and the fetch failed/offline
  "book_unknown"           the server returned 404 for this book
  "no_digest_for_book" the book is known but has no digest yet
  "chapter_not_matched"    could not match the current chapter to a cached item
  "client_upgrade_required" the server refuses to serve this plugin version

The third return value is only filled in for that last kind, and carries the
refusal itself so the reader can be told which version the server wants.
]]

local logger = require("logger")
local Network = require("modules/network")
local TitleMatch = require("modules/title_match")
local UpgradeRequired = require("modules/upgrade_required")

-- Chapter titles are matched the same way everywhere; see modules/title_match.
local normalizeTitle = TitleMatch.normalize

local DigestService = {}
DigestService.__index = DigestService

-- How old a "fetched, but empty" cache entry has to be before opening the
-- popup re-checks the server. Digests are generated asynchronously, so a book
-- fetched before its digests existed would otherwise stay empty until a sync
-- happened to refresh it.
local STALE_EMPTY_REFETCH_SECONDS = 900

--- Create a new DigestService instance
-- @param api_client ApiClient instance for server communication
-- @param digest_cache DigestCache instance for local caching
-- @return DigestService instance
function DigestService:new(api_client, digest_cache)
	local instance = setmetatable({}, DigestService)
	instance.api_client = api_client
	instance.cache = digest_cache
	return instance
end

--- Get the current rendered page number from the UI, defensively
-- @param ui table The KOReader UI context
-- @return number|nil The current page, or nil if unavailable
local function getCurrentPage(ui)
	if not ui then
		return nil
	end

	-- Primary: rendered page from the view state (same source as SessionTracker)
	if ui.view and ui.view.state and ui.view.state.page then
		return ui.view.state.page
	end

	-- Fallback: ask the document directly, wrapped in pcall
	local ok, page = pcall(function()
		if ui.document and ui.document.getCurrentPage then
			return ui.document:getCurrentPage()
		end
		return nil
	end)

	if ok and page then
		return page
	end

	return nil
end

--- Find the current ToC entry: the last flat entry whose page <= current page
-- @param ui table The KOReader UI context
-- @return number|nil The 1-based index of the current entry into ui.toc.toc
-- @return table|nil The current ToC entry
local function findCurrentTocEntry(ui)
	local ok, toc = pcall(function()
		return ui.toc and ui.toc.toc
	end)

	if not ok or not toc or #toc == 0 then
		return nil, nil
	end

	local current_page = getCurrentPage(ui)
	if not current_page then
		return nil, nil
	end

	local current_index, current_entry = nil, nil
	for i, entry in ipairs(toc) do
		local entry_page = tonumber(entry.page)
		if entry_page and entry_page <= current_page then
			-- Keep advancing; the last matching entry is the current chapter
			current_index = i
			current_entry = entry
		end
	end

	return current_index, current_entry
end

--- Find the KOReader parent title for a ToC entry by walking backwards to the
--- nearest entry with a smaller depth
-- @param toc table The flat ToC array
-- @param index number The 1-based index of the current entry
-- @return string|nil The parent entry title, or nil if there is no parent
local function findParentTitle(toc, index)
	local current_entry = toc[index]
	if not current_entry then
		return nil
	end

	local current_depth = tonumber(current_entry.depth)
	if not current_depth then
		return nil
	end

	for i = index - 1, 1, -1 do
		local entry = toc[i]
		local depth = entry and tonumber(entry.depth)
		if depth and depth < current_depth then
			return entry.title
		end
	end

	return nil
end

--- Stage 1: items whose chapter_name matches the ToC title
-- @param items table Array of cached digest items
-- @param toc_title_norm string|nil Normalized ToC title
-- @return table Array of matching items (preserves input order)
local function matchByTitle(items, toc_title_norm)
	local matches = {}
	for _, item in ipairs(items) do
		if normalizeTitle(item.chapter_name) == toc_title_norm then
			table.insert(matches, item)
		end
	end
	return matches
end

--- Stage 2: filter candidates by parent title (both nil counts as a match)
-- @param candidates table Array of stage-1 items
-- @param parent_title_norm string|nil Normalized KOReader parent title
-- @return table Array of matching items
local function matchByParent(candidates, parent_title_norm)
	local matches = {}
	for _, item in ipairs(candidates) do
		if normalizeTitle(item.parent_chapter_name) == parent_title_norm then
			table.insert(matches, item)
		end
	end
	return matches
end

--- Stage 3: pick by occurrence index.
--- Counts which occurrence of this normalized title the current ToC entry is,
--- then returns that Nth stage-1 candidate in chapter_number order.
-- @param toc table The flat ToC array
-- @param current_index number Index of the current entry
-- @param toc_title_norm string|nil Normalized ToC title
-- @param stage1 table Array of stage-1 candidate items
-- @return table|nil The matched item, or nil if out of range
local function matchByOccurrence(toc, current_index, toc_title_norm, stage1)
	-- Determine the occurrence position (1-based) of the current entry among
	-- all ToC entries sharing the same normalized title.
	local occurrence = 0
	for i, entry in ipairs(toc) do
		if normalizeTitle(entry.title) == toc_title_norm then
			occurrence = occurrence + 1
			if i == current_index then
				break
			end
		end
	end

	if occurrence < 1 then
		return nil
	end

	-- Order stage-1 candidates by chapter_number for a stable Nth pick.
	local ordered = {}
	for _, item in ipairs(stage1) do
		table.insert(ordered, item)
	end
	table.sort(ordered, function(a, b)
		return (tonumber(a.chapter_number) or 0) < (tonumber(b.chapter_number) or 0)
	end)

	if occurrence <= #ordered then
		return ordered[occurrence]
	end

	return nil
end

--- Match the current chapter against the cached items using staged matching
-- @param ui table The KOReader UI context
-- @param items table Array of cached digest items
-- @return table|nil The matched item, or nil if it could not be matched
local function matchCurrentChapter(ui, items)
	local current_index, current_entry = findCurrentTocEntry(ui)
	if not current_entry then
		logger.dbg("Crossbill DigestService: No current ToC entry could be resolved")
		return nil
	end

	local toc = ui.toc.toc
	local toc_title_norm = normalizeTitle(current_entry.title)
	local parent_title_norm = normalizeTitle(findParentTitle(toc, current_index))

	-- Stage 1: match by chapter title.
	local stage1 = matchByTitle(items, toc_title_norm)
	if #stage1 == 0 then
		logger.dbg("Crossbill DigestService: No digest item matches the current chapter title")
		return nil
	end
	if #stage1 == 1 then
		return stage1[1]
	end

	-- Stage 2: disambiguate by parent title.
	local stage2 = matchByParent(stage1, parent_title_norm)
	if #stage2 == 1 then
		return stage2[1]
	end

	-- Stage 3: disambiguate by occurrence index among stage-1 candidates.
	return matchByOccurrence(toc, current_index, toc_title_norm, stage1)
end

--- Fetch a book's digests from the server and replace the cache
-- Caller is responsible for WiFi lifecycle.
-- @param client_book_id string The client book ID
-- @return boolean ok True if fetched and cached successfully
-- @return string|nil err_kind "book_unknown" (404), "client_upgrade_required"
--   or "fetch_failed", nil on success
-- @return table|nil err The refusal, for "client_upgrade_required" only
function DigestService:refreshBook(client_book_id)
	if not client_book_id then
		return false, "fetch_failed"
	end

	local code, data, err = self.api_client:getBookDigest(client_book_id)

	if UpgradeRequired.is(err) then
		-- Not a digest problem: the server serves this plugin nothing until it
		-- is updated, and that is what the reader has to hear.
		logger.warn("Crossbill DigestService: The server refuses this plugin version")
		return false, UpgradeRequired.KIND, err
	end

	if code == 404 then
		logger.dbg("Crossbill DigestService: Book unknown to server (404)")
		return false, "book_unknown"
	end

	if code ~= 200 or not data then
		logger.warn("Crossbill DigestService: Failed to fetch digests:", err or tostring(code))
		return false, "fetch_failed"
	end

	local items = data.items or {}
	local ok = self.cache:replaceBook(client_book_id, items)
	if not ok then
		return false, "fetch_failed"
	end

	logger.dbg("Crossbill DigestService: Cached", #items, "digest items for", client_book_id)
	return true, nil
end

--- Re-fetch a book whose cache is present but empty, if that is worth trying
-- Only re-fetches an old enough empty cache, and only when the device is
-- already online: an offline device must not be prompted for WiFi or made to
-- wait for a request that cannot succeed.
-- @param client_book_id string The client book ID
-- @return table Cached items after the attempt (empty if it was skipped or failed)
-- @return string|nil err_kind Why the re-fetch failed, nil when it did not run
--   or succeeded
-- @return table|nil err The refusal, for "client_upgrade_required" only
function DigestService:_refetchStaleEmptyBook(client_book_id)
	local fetched_at = self.cache:getFetchedAt(client_book_id)
	if not fetched_at then
		return {}
	end

	local age = os.time() - fetched_at
	if age < STALE_EMPTY_REFETCH_SECONDS then
		return {}
	end

	if not Network.isConnected() then
		logger.dbg("Crossbill DigestService: Empty digest cache is stale but the device is offline")
		return {}
	end

	logger.dbg("Crossbill DigestService: Re-fetching empty digest cache, last fetched", age, "seconds ago")
	local ok, err_kind, err = self:refreshBook(client_book_id)
	if not ok then
		-- Why it failed is the caller's to weigh: a refusal is not about this
		-- book at all and must not be reported as a missing digest.
		return {}, err_kind, err
	end

	return self.cache:getBook(client_book_id) or {}
end

--- Resolve the digest item for the current chapter
-- Tries the cache first; if the book is absent, fetches it, then matches the
-- current chapter against the cached items.
-- @param ui table The KOReader UI context
-- @param client_book_id string The client book ID
-- @return table|nil item The matched digest item, or nil
-- @return string|nil err_kind One of the documented error kinds, nil on success
-- @return table|nil err The refusal, for "client_upgrade_required" only
function DigestService:getForCurrentChapter(ui, client_book_id)
	if not client_book_id then
		return nil, "no_cache"
	end

	-- Populate the cache if this book has never been fetched.
	if not self.cache:hasBook(client_book_id) then
		local ok, refresh_err, err = self:refreshBook(client_book_id)
		if not ok then
			if refresh_err == "book_unknown" then
				return nil, "book_unknown"
			end
			if refresh_err == UpgradeRequired.KIND then
				-- Not an empty cache: no amount of waiting for WiFi will fix a
				-- plugin the server refuses.
				return nil, refresh_err, err
			end
			return nil, "no_cache"
		end
	end

	local items = self.cache:getBook(client_book_id)
	if not items or #items == 0 then
		-- The book was fetched but had no digests then; the server may have
		-- generated them since.
		local refetch_kind, refetch_err
		items, refetch_kind, refetch_err = self:_refetchStaleEmptyBook(client_book_id)
		if refetch_kind == UpgradeRequired.KIND then
			-- Swallowed here, the refusal would surface as "no digest for this
			-- book yet" and send the reader off to generate one that may exist.
			return nil, refetch_kind, refetch_err
		end
	end

	if not items or #items == 0 then
		return nil, "no_digest_for_book"
	end

	local item = matchCurrentChapter(ui, items)
	if not item then
		return nil, "chapter_not_matched"
	end

	return item, nil
end

return DigestService
