local Journal = require("storygraph/lib/journal_verification")
local loadApi = require("spec/support/load_api")
local Queue = require("storygraph/lib/sync_queue")
local Sender = require("storygraph/lib/sync_sender")
local Dispatcher = require("storygraph/lib/sync_dispatcher")

local function fixture(name)
  local f = assert(io.open("spec/fixtures/" .. name .. ".html"))
  local s = f:read("*a"); f:close(); return s
end
local function journal(ids)
  local links = {}
  for _, id in ipairs(ids) do
    links[#links + 1] = '<a href="/journal_entries/' .. id .. '/edit?return_to=x">Edit</a>'
  end
  return '<div><a href="/books/book-1">Edition</a><span class="journal-entry-panes">'
    .. table.concat(links) .. '</span></div>'
end
local function note()
  return { book_id = "book-1", entry = "Synthetic & exact note\nSecond line",
    progress = 40, progress_type = "percentage", date = { day = 27, month = 9, year = 2026 } }
end
local function scenario(options)
  options = options or {}
  local api, calls, posts = loadApi(), {}, 0
  api.request = function(_, url, method)
    calls[#calls + 1] = { url = url, method = method }
    if method == "POST" then
      posts = posts + 1
      return options.post_code, "", options.post_headers
    end
    if url:find("/books/", 1, true) then return 200, fixture("reading"), {} end
    if url:find("/journal?", 1, true) then
      if options.throw then error("synthetic read failure") end
      if posts == 0 then return options.before_code or 200, options.before or fixture("journal"), {} end
      if options.throw_after then error("synthetic verification failure") end
      return options.after_code or 200, options.after or journal({"old-entry", "new-entry"}), {}
    end
    if url:find("/journal_entries/", 1, true) then
      return options.edit_code or 200, options.edit or fixture("journal_entry"), {}
    end
    error("unexpected request")
  end
  return api, calls, function() return posts end
end

describe("Remote journal recognition", function()
  it("recognizes the edition-scoped journal and exact form fields", function()
    assert.same({["old-entry"] = true}, Journal:snapshot(fixture("journal"), "book-1"))
    assert.is_true(Journal:matches(fixture("journal_entry"), "new-entry", note()))
    local pages = note(); pages.progress_type, pages.progress = "pages", 80
    assert.is_true(Journal:matches(fixture("journal_entry"), "new-entry", pages))
  end)

  it("rejects another edition, login, partial pages and unknown markup", function()
    assert.is_nil(Journal:snapshot(fixture("journal"), "other-book"))
    for _, extra in ipairs({ '<a rel="next" href="/journal?page=2">Next</a>',
        '<div class="pagination"></div>', '<turbo-frame src="/more"></turbo-frame>',
        '<form action="/users/sign_in"></form>' }) do
      assert.is_nil(Journal:snapshot(fixture("journal") .. extra, "book-1"))
    end
    assert.is_nil(Journal:snapshot("<html>Unknown</html>", "book-1"))
  end)

  it("requires exactly one new ID and retains every baseline ID", function()
    local before = { old = true }
    assert.equals("new", Journal:newEntry(before, {old=true, new=true}))
    assert.is_nil(Journal:newEntry(before, {old=true}))
    assert.is_nil(Journal:newEntry(before, {old=true, new=true, another=true}))
    assert.is_nil(Journal:newEntry(before, {new=true}))
  end)

  it("recognizes an empty scoped journal but refuses oversized or changed contracts", function()
    assert.same({}, Journal:snapshot(journal({}), "book-1"))
    local ids = {}
    for i = 1, 201 do ids[i] = "entry-" .. i end
    assert.is_nil(Journal:snapshot(journal(ids), "book-1"))
    assert.is_nil(Journal:snapshot(fixture("journal"):gsub("/edit%?", "/unknown?"), "book-1"))
  end)

  it("decodes numeric Unicode entities without weakening exact text matching", function()
    local html = fixture("journal_entry"):gsub("Synthetic", "&#x1F642;")
    local n = note(); n.entry = n.entry:gsub("Synthetic", "\240\159\153\130")
    assert.is_true(Journal:matches(html, "new-entry", n))
    assert.is_false(Journal:matches(html:gsub("&#x1F642;", "&unknown;"), "new-entry", n))
  end)

  it("does not collapse different text, dates, progress, IDs or rich formatting", function()
    local html = fixture("journal_entry")
    local n = note(); n.entry = n.entry .. " "
    assert.is_false(Journal:matches(html, "new-entry", n))
    n = note(); n.date.day = 26
    assert.is_false(Journal:matches(html, "new-entry", n))
    n = note(); n.progress = 41
    assert.is_false(Journal:matches(html, "new-entry", n))
    assert.is_false(Journal:matches(html, "another-entry", note()))
    assert.is_false(Journal:matches(html:gsub("Synthetic", "&lt;strong&gt;Synthetic&lt;/strong&gt;"), "new-entry", note()))
    assert.is_false(Journal:matches(html:gsub('value="27" selected="selected"', 'value="27"'), "new-entry", note()))
  end)
end)

describe("Automatic verification after uncertain note delivery", function()
  it("confirms a lost POST response from a new matching remote entry without resending", function()
    local api, calls, posts = scenario()
    local result, outcome = api:createJournalEntry(note())
    assert.equals("confirmed", outcome.status)
    assert.is_true(result._storygraph_refresh)
    assert.equals(1, posts())
    assert.equals(5, #calls)
    assert.equals("POST", calls[3].method)
    assert.equals("GET", calls[4].method)
    assert.equals("GET", calls[5].method)
  end)

  it("also verifies an unrecognized redirect instead of accepting the 302 alone", function()
    local api = scenario { post_code = 302, post_headers = {location="/journal?book_id=book-1"} }
    local _, outcome = api:createJournalEntry(note())
    assert.equals("confirmed", outcome.status)
  end)

  it("keeps an uncertain note on missing, ambiguous, unreadable or mismatched evidence", function()
    for _, options in ipairs({
      { before_code = 503 }, { before = "unknown markup" }, { throw = true }, { throw_after = true },
      { after = journal({"old-entry"}) },
      { after = journal({"old-entry", "new-entry", "other-entry"}) },
      { after = journal({"new-entry"}) }, { after_code = 503 },
      { edit_code = 401 }, { edit = '<form action="/users/sign_in"></form>' },
      { edit = fixture("journal_entry"):gsub("Synthetic", "Different") },
    }) do
      local api, _, posts = scenario(options)
      local result, outcome = api:createJournalEntry(note())
      assert.is_nil(result)
      assert.equals("uncertain", outcome.status)
      assert.equals(1, posts())
    end
  end)

  it("does not depend on verification for confirmed or rejected responses", function()
    for _, code in ipairs({204, 401, 422}) do
      local api, calls, posts = scenario { post_code = code }
      local _, outcome = api:createJournalEntry(note())
      assert.equals(code == 204 and "confirmed" or "rejected", outcome.status)
      assert.equals(3, #calls)
      assert.equals(1, posts())
    end
  end)

  it("removes only a remotely confirmed note from the durable queue", function()
    for _, confirmed in ipairs({true, false}) do
      local disk = { readSetting = function(self) return self.data end,
        saveSetting = function(self, _, data) self.data = data end, flush = function() end }
      local queue = Queue:new {storage=disk}
      queue:enqueue { kind="note", document="book.epub", book_id="book-1", payload=note() }
      local api, _, posts = scenario(confirmed and {} or { after=journal({"old-entry"}) })
      local sender = Sender:new {api=api}
      local dispatcher = Dispatcher:new {queue=queue, is_connected=function() return true end,
        send=function(op) return sender:send(op) end}
      assert.equals(confirmed, dispatcher:drainOne())
      assert.equals(confirmed and 0 or 1, Queue:new {storage=disk}:count())
      dispatcher:drainOne()
      assert.equals(1, posts())
    end
  end)
end)
