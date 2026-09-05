--[[
Stand-in for the plugin's own `modules/network`.

Network is the one module that must not run under test, being the one that
opens sockets, and it is the plugin's own rather than one of KOReader's, so it
cannot be shadowed from `spec/support/koreader`: `crossbill.koplugin` comes
first on the path. A spec keeps it off the wire by seeding the package cache
with an instance of this fake before requiring the module under test, and
putting the real module back afterwards so nothing else sees the fake.

Every spec that does so used to carry its own version of this, each covering
the slice of the module it needed. This one covers the union: the four kinds of
request the plugin makes, each recording what it was asked for and answering
with what the test queued, and the three WiFi calls.

An instance per spec rather than one shared table: busted runs every spec in
one process, and a `connected` or a queued answer left behind by one file would
otherwise decide what another file's requests do.

The four request kinds are built by `channel`, which is what makes the setters
this file has no literal spelling of -- `setGetResult` and `setGetResults`,
`setPostResult` and `setPostResults`, and the same pair for `Form` and
`Multipart`. The singular queues one tuple for every call of that kind; the
plural queues one per call, the last standing for the calls after it, which is
what a request the client retries needs.

Follows `spec/support/fake_session_store.lua` in shape: `new` hands back a
table, and specs reach into its fields.
]]

local FakeNetwork = {}

--- Answer the nth call with the nth queued tuple, the last one from then on
-- @param results table Array of { code, body, err } tuples
-- @param calls table The calls recorded so far, this one included
-- @return number|nil, table|string|nil, string|nil The queued status, body and error
local function answer(results, calls)
	local result = results[math.min(#calls, #results)] or {}
	return result[1], result[2], result[3]
end

--- Create a fake nothing has asked anything of yet
-- @param options table|nil `connected`, which the fake also returns to after a
--   reset; offline unless a spec says otherwise
-- @return table The fake, ready to be seeded into `package.loaded`
function FakeNetwork:new(options)
	options = options or {}
	local starts_connected = options.connected == true

	local fake = {
		-- Whether the device has a connection, as the current test decided
		connected = starts_connected,
		-- How often the sync put the WiFi back as it found it
		wifi_disabled = 0,
		-- What `whenOnline` was handed while offline, waiting to be run
		waiting = nil,
	}

	-- The queued answers, per request kind, keyed by the field its calls are
	-- recorded in. Held here rather than on the fake so a spec queues answers
	-- through the setters, which is the surface that stays put.
	local queues = {}

	--- Give the fake one kind of request: a record, a queue and its setters
	-- @param record string The field the calls of this kind are recorded in
	-- @param name string The name the setters are built from ("Get", "Post", ...)
	-- @return function Records a call and returns the answer queued for it
	local function channel(record, name)
		fake[record] = {}
		queues[record] = { {} }

		fake["set" .. name .. "Result"] = function(code, body, err)
			queues[record] = { { code, body, err } }
		end

		fake["set" .. name .. "Results"] = function(...)
			queues[record] = { ... }
		end

		return function(call)
			table.insert(fake[record], call)
			return answer(queues[record], fake[record])
		end
	end

	local answerGet = channel("requested", "Get")
	local answerPost = channel("posted_json", "Post")
	local answerForm = channel("posted_forms", "Form")
	local answerMultipart = channel("uploaded", "Multipart")

	--- Answer `getJson` with whatever the current test has queued
	-- @param url string The URL being fetched
	-- @param token string|nil The bearer token
	-- @param extra_headers table|nil The headers the caller added
	-- @return number|nil, table|nil, string|nil The queued status, body and error
	function fake.getJson(url, token, extra_headers)
		return answerGet({ url = url, token = token, headers = extra_headers })
	end

	--- Answer `postJson` with whatever the current test has queued
	-- @param url string The URL being posted to
	-- @param data table The payload the caller built
	-- @param token string|nil The bearer token
	-- @return number|nil, table|nil, string|nil The queued status, body and error
	function fake.postJson(url, data, token)
		return answerPost({ url = url, data = data, token = token })
	end

	--- Answer `postForm` with whatever the current test has queued
	-- @param url string The URL being posted to
	-- @param data table The form fields the caller sent
	-- @return number|nil, table|nil, string|nil The queued status, body and error
	function fake.postForm(url, data)
		return answerForm({ url = url, data = data })
	end

	--- Answer `postMultipart` with whatever the current test has queued
	-- Answers with the body undecoded, as the real module does.
	-- @param url string The URL being posted to
	-- @param files table The files the caller built
	-- @param token string|nil The bearer token
	-- @return number|nil, string|nil, string|nil The queued status, body and error
	function fake.postMultipart(url, files, token)
		return answerMultipart({ url = url, files = files, token = token })
	end

	--- Run the work now if the device is online, hold it if it is not
	-- The real module hands an offline callback to KOReader, which runs it once
	-- the reader connects; here it waits in `waiting` for a spec to run it.
	-- @param fn function What to run once there is a connection
	function fake.whenOnline(fn)
		if fake.connected then
			fn()
			return
		end
		fake.waiting = fn
	end

	--- Count a request to put the WiFi back as the sync found it
	function fake.disableWifiIfNeeded()
		fake.wifi_disabled = fake.wifi_disabled + 1
	end

	--- Whether the device has a connection
	-- @return boolean The state the current test left
	function fake.isConnected()
		return fake.connected == true
	end

	--- Forget the requests made, the queued answers and the WiFi
	function fake.reset()
		for record in pairs(queues) do
			fake[record] = {}
			queues[record] = { {} }
		end
		fake.connected = starts_connected
		fake.wifi_disabled = 0
		fake.waiting = nil
	end

	return fake
end

return FakeNetwork
