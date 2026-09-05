local loadApi = require("spec/support/load_api")
local Queue = require("storygraph/lib/sync_queue")
local Sender = require("storygraph/lib/sync_sender")
local Dispatcher = require("storygraph/lib/sync_dispatcher")

local function fixture()
  local f = assert(io.open("spec/fixtures/reading.html"))
  local html = f:read("*a"); f:close(); return html
end
local function storage()
  return { readSetting = function(self) return self.data end,
    saveSetting = function(self, _, data) self.data = data end, flush = function() end }
end
local function dispatcher(queue, api)
  local sender = Sender:new { api = api }
  return Dispatcher:new { queue = queue, is_connected = function() return true end,
    send = function(op) return sender:send(op) end }
end
local function note(queue)
  queue:enqueue { kind = "note", document = "book.epub", book_id = "book-1",
    payload = { entry = "Synthetic note", progress = 40 } }
end

describe("Durable mutation delivery", function()
  it("does not repeat a note after a lost response and restart", function()
    local disk = storage()
    local q = Queue:new { storage = disk }
    note(q)
    local api, posts = loadApi(), 0
    api.request = function(_, _, method)
      if method == "GET" then return 200, fixture(), {} end
      posts = posts + 1
      return nil, "timeout"
    end
    assert.is_false(dispatcher(q, api):drainOne())
    q = Queue:new { storage = disk }
    local success, reason = dispatcher(q, api):drainOne()
    assert.is_true(success)
    assert.are.equal("empty", reason) -- uncertain note is suspended, not resent
    assert.are.equal(1, posts)
    assert.are.equal(1, q:count())
  end)

  it("does not repeat an acknowledged note if deleting it from disk failed", function()
    local disk, api = storage(), loadApi()
    local q = Queue:new { storage = disk }
    note(q)
    local posts = 0
    api.request = function(_, _, method)
      if method == "GET" then return 200, fixture(), {} end
      posts = posts + 1
      disk.flush = function() error("disk full") end
      return 204, "", {}
    end
    assert.is_false(dispatcher(q, api):drainOne())
    disk.flush = function() end
    q = Queue:new { storage = disk }
    assert.is_true(dispatcher(q, api):drainOne()) -- no eligible operation
    assert.are.equal(1, posts)
  end)

  it("reconciles progress by reading after a successful POST and failed refresh", function()
    local disk, api = storage(), loadApi()
    local q = Queue:new { storage = disk }
    q:enqueue { kind = "progress", document = "book.epub", book_id = "book-1",
      payload = { value = 80, update_type = "pages", allow_regression = true } }
    local posts, fail_refresh = 0, true
    api.request = function(_, _, method)
      if method == "POST" then posts = posts + 1; return 204, "", {} end
      if posts > 0 and fail_refresh then return nil, "timeout" end
      return 200, fixture(), {}
    end
    assert.is_false(dispatcher(q, api):drainOne())
    fail_refresh = false
    q = Queue:new { storage = disk, now = function() return os.time() + 3600 end }
    assert.is_true(dispatcher(q, api):drainOne())
    assert.are.equal(1, posts)
    assert.are.equal(0, q:count())
  end)

  it("does not send when the in-flight marker cannot be persisted", function()
    local disk = storage()
    local q = Queue:new { storage = disk }
    note(q)
    disk.flush = function() error("disk full") end
    local called = false
    local api = { createJournalEntry = function() called = true end }
    local success, reason = dispatcher(q, api):drainOne()
    assert.is_false(success)
    assert.are.equal("persist_failed", reason)
    assert.is_false(called)
  end)
end)

describe("Queue schema migration", function()
  it("upgrades v1 without losing notes, order or paused documents", function()
    local disk = storage()
    disk.data = { version = 1, next_id = 3, paused_documents = { ["book.epub"] = true }, operations = {
      {id=1, kind="note", document="book.epub", book_id="book-1", payload={entry="Synthetic"}},
      {id=2, kind="status", document="book.epub", book_id="book-1", payload={status_id=2}},
    } }
    local q = Queue:new {storage=disk}
    assert.are.equal(2, q:count())
    assert.is_nil(q:start())
    assert.is_true(q:resumeDocument("book.epub"))
    assert.are.equal(2, disk.data.version)
    assert.are.equal("note", q:start().kind)
  end)
end)
