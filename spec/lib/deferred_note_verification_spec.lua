local loadApi = require("spec/support/load_api")
local Queue = require("storygraph/lib/sync_queue")
local Sender = require("storygraph/lib/sync_sender")
local Dispatcher = require("storygraph/lib/sync_dispatcher")
local Policy = require("storygraph/lib/note_verification")

local function fixture(name)
  local f = assert(io.open("spec/fixtures/" .. name .. ".html"))
  local text = f:read("*a"); f:close(); return text
end
local function journal(new_entries)
  local text = fixture("journal")
  for _, id in ipairs(new_entries or {}) do
    text = text:gsub("</span>", '<a href="/journal_entries/' .. id .. '/edit?return_to=x">Edit</a></span>')
  end
  return text
end

local function harness()
  local h = {now=1000, online=true, posts=0, reads=0, logs={}, after=journal()}
  h.disk = {readSetting=function(self) return self.data end,
    saveSetting=function(self, _, data) self.data=data end, flush=function() end}
  local function log(...)
    local parts = {}; for _, v in ipairs({...}) do parts[#parts + 1] = tostring(v) end
    h.logs[#h.logs + 1] = table.concat(parts, " ")
  end
  h.api = loadApi {logger={info=log, warn=log, err=log}}
  h.api.request = function(_, url, method)
    if method == "POST" then
      h.posts = h.posts + 1
      if h.on_post then h.on_post() end
      return h.post_code, "", h.post_headers
    end
    h.reads = h.reads + 1
    if url:find("/books/", 1, true) then return 200, fixture("reading"), {} end
    if url:find("/journal?", 1, true) then
      if h.posts == 0 then return h.before_code or 200, h.before or journal(), {} end
      if h.read_error then error("PRIVATE exception with credential=secret") end
      return h.after_code or 200, h.after, h.after_headers or {}
    end
    return h.edit_code or 200, h.edit or fixture("journal_entry"), h.edit_headers or {}
  end
  function h:restore()
    self.queue = Queue:new {storage=self.disk, now=function() return self.now end}
    local sender = Sender:new {api=self.api}
    self.worker = Dispatcher:new {queue=self.queue, is_connected=function() return self.online end,
      send=function(op, save) return sender:send(op, save) end}
  end
  h:restore()
  h.operation = h.queue:enqueue {kind="note", document="book.epub", book_id="book-1", payload={
    entry="Synthetic & exact note\nSecond line", progress=40, progress_type="percentage",
    date={day=27, month=9, year=2026},
  }}
  return h
end

describe("Deferred GET-only note verification", function()
  it("persists evidence before POST and confirms an entry that appears later", function()
    local h = harness()
    h.on_post = function()
      local stored = Queue:new {storage=h.disk}:list()[1]
      assert.equals("in_flight", stored.delivery_state)
      assert.same({["old-entry"]=true}, stored.note_verification.before)
    end
    assert.is_false(h.worker:drainOne())
    assert.equals(1060, h.queue:nextAttemptAt())
    assert.equals("entry_absent", h.queue:list()[1].verification_reason)
    h:restore()
    h.after = journal({"new-entry"})
    h.now = 1060
    assert.is_true(h.worker:drainOne())
    assert.equals(0, h.queue:count())
    assert.equals(1, h.posts)
  end)

  it("waits offline and observes the persisted deadline on reconnect", function()
    local h = harness()
    h.worker:drainOne()
    local reads = h.reads
    h.online = false; h.now = 1050
    assert.is_false(h.worker:drainOne())
    h.online = true
    local ok, reason = h.worker:drainOne()
    assert.is_true(ok); assert.equals("empty", reason)
    assert.equals(reads, h.reads)
    h.now = 1100; h.after = journal({"new-entry"})
    assert.is_true(h.worker:drainOne())
    assert.equals(0, h.queue:count())
    assert.equals(1, h.posts)
  end)

  it("stops after three persisted deferred checks even across restarts", function()
    local h = harness()
    h.worker:drainOne()
    for attempt, deadline in ipairs({1060, 1180, 1420}) do
      assert.equals(deadline, h.queue:nextAttemptAt())
      h:restore(); h.now=deadline
      assert.is_false(h.worker:drainOne())
      assert.equals(attempt, h.queue:list()[1].note_verification.attempts)
      assert.equals(1, h.posts)
    end
    assert.equals("reconciliation", h.queue:list()[1].blocked_reason)
    assert.is_nil(h.queue:nextAttemptAt())
    local reads = h.reads
    h:restore(); h.now=99999
    h.queue:credentialsChanged()
    assert.is_nil(h.queue:retryOperation(h.operation.id))
    h.worker:drainOne()
    assert.equals(reads, h.reads)
    assert.equals(1, h.queue:count())
  end)

  it("stops on ambiguous, changed or mismatched evidence", function()
    for _, kind in ipairs({"ambiguous", "changed", "mismatch", "unknown"}) do
      local h = harness()
      if kind == "ambiguous" then h.after=journal({"new-entry", "other-entry"}) end
      if kind == "changed" then h.after=journal({"new-entry"}):gsub("old%-entry", "replacement") end
      if kind == "mismatch" then h.after=journal({"new-entry"}); h.edit=fixture("journal_entry"):gsub("Synthetic", "Other") end
      if kind == "unknown" then h.after="<html>Unsupported</html>" end
      assert.is_false(h.worker:drainOne())
      assert.is_nil(h.queue:nextAttemptAt())
      assert.equals("reconciliation", h.queue:list()[1].blocked_reason)
      h:restore(); h.now=99999; h.worker:drainOne()
      assert.equals(1, h.posts)
    end
  end)

  it("keeps notes without a baseline manual-only", function()
    local h = harness(); h.before_code=503
    assert.is_false(h.worker:drainOne())
    assert.is_nil(h.queue:list()[1].note_verification)
    assert.is_nil(h.queue:nextAttemptAt())
    h:restore(); h.now=99999; h.worker:drainOne()
    assert.equals(1, h.posts)
  end)

  it("does not send if the baseline read discovers an expired session", function()
    local h=harness(); h.before_code=401
    assert.is_false(h.worker:drainOne())
    assert.is_true(h.queue:isAuthBlocked())
    assert.equals(0, h.posts)
  end)

  it("cannot reset the budget by replacing evidence during a deferred check", function()
    local h=harness(); h.worker:drainOne(); h.now=1060
    local op=h.queue:start()
    op.note_verification.attempts=0
    local saved, reason=h.queue:prepareNoteVerification(op.id,op.note_verification)
    assert.is_nil(saved); assert.equals("invalid_verification",reason)
    assert.equals(1,h.queue:list()[1].note_verification.attempts)
  end)

  it("keeps invalid persisted evidence manual-only instead of sending again", function()
    for _, field in ipairs({"attempts", "before", "book_id"}) do
      local h=harness(); h.worker:drainOne()
      h.disk.data.operations[1].note_verification[field]="invalid"
      h:restore(); h.now=99999
      local reads=h.reads
      h.worker:drainOne()
      assert.is_nil(h.queue:nextAttemptAt())
      assert.equals(reads,h.reads)
      assert.equals(1,h.posts)
      assert.equals(1,h.queue:count())
    end
  end)

  it("does not POST when evidence persistence fails or exceeds storage limits", function()
    for _, mode in ipairs({"disk", "capacity"}) do
      local h = harness()
      local prepare = h.queue.prepareNoteVerification
      h.queue.prepareNoteVerification = function(self, ...)
        if mode == "disk" then h.disk.flush=function() error("disk full") end
        else self.max_bytes=1 end
        local saved, reason = prepare(self, ...)
        h.disk.flush=function() end
        return saved, reason
      end
      assert.is_false(h.worker:drainOne())
      assert.equals(0, h.posts)
      assert.equals(1, h.queue:count())
      assert.equals("verification_storage_failed", h.queue:list()[1].last_error)
    end
  end)

  it("reserves each check before I/O so repeated crashes cannot reset the budget", function()
    local h = harness(); h.worker:drainOne()
    for attempt = 1, 3 do
      h.now=h.queue:nextAttemptAt()
      local op = h.queue:start() -- crash before any GET
      assert.equals(attempt, op.note_verification.attempts)
      h:restore()
    end
    assert.is_nil(h.queue:nextAttemptAt())
    assert.equals(1, h.posts)
    assert.equals(1, h.queue:count())
  end)

  it("does not read when persisting the check counter fails", function()
    local h = harness(); h.worker:drainOne(); h.now=1060
    local reads=h.reads
    h.disk.flush=function() error("disk full") end
    local ok, reason=h.worker:drainOne()
    assert.is_false(ok); assert.equals("persist_failed", reason)
    assert.equals(reads, h.reads)
    assert.equals(0, h.queue:list()[1].note_verification.attempts)
  end)

  it("resumes read-only checks after authentication recovery without resetting the budget", function()
    local h = harness(); h.after_code=401
    h.worker:drainOne()
    assert.is_true(h.queue:isAuthBlocked())
    h:restore(); h.queue:credentialsChanged()
    h.after_code=200; h.after=journal({"new-entry"})
    assert.is_true(h.worker:drainOne())
    assert.equals(0, h.queue:count())
    assert.equals(1, h.posts)
  end)

  it("honors Retry-After for journal reads", function()
    local h = harness(); h.after_code=429; h.after_headers={["retry-after"]="7200"}
    h.worker:drainOne()
    assert.equals(8200, h.queue:nextAttemptAt())
    assert.equals(1, h.posts)
  end)

  it("discards the old evidence only after explicit permission to resend", function()
    local h=harness(); h.worker:drainOne()
    assert.is_true(h.queue:resolveNote(h.operation.id, false))
    local op=h.queue:list()[1]
    assert.is_nil(op.note_verification)
    assert.is_nil(op.delivery_state)
    assert.is_nil(op.verification_reason)
    h.worker:drainOne()
    assert.equals(2, h.posts)
  end)

  it("uses bounded verification after a crash with persisted evidence but no outcome", function()
    local h=harness()
    local send=h.worker.send
    h.worker.send=function(op, save)
      local result, state, reason, outcome=send(op, save)
      h.disk.flush=function() error("outcome persistence failed") end
      return result, state, reason, outcome
    end
    h.worker:drainOne()
    h.disk.flush=function() end
    h:restore(); h.now=1060; h.after=journal({"new-entry"})
    assert.is_true(h.worker:drainOne())
    assert.equals(0, h.queue:count())
    assert.equals(1, h.posts)
  end)
end)

describe("Safe note verification diagnostics", function()
  it("logs reasons and route templates without query strings, IDs or exceptions", function()
    local h=harness()
    h.post_code=302
    h.post_headers={location="https://app.thestorygraph.com/journal?token=PRIVATE#secret"}
    h.read_error=true
    h.worker:drainOne()
    local logs=table.concat(h.logs, "\n")
    assert.matches("redirect=/journal", logs, 1, true)
    assert.matches("result=verification_exception", logs, 1, true)
    assert.is_nil(logs:find("PRIVATE", 1, true))
    assert.is_nil(logs:find("secret", 1, true))
    assert.is_nil(logs:find("Synthetic", 1, true))
    assert.equals("/books/:id", Policy:redirect {location="/books/private-id?token=secret"})
    assert.equals("other", Policy:redirect {location="https://external.invalid/secret"})
    assert.equals("other", Policy:redirect {location="/private-secret-path"})
    assert.equals("verification_exception", Policy:reason("PRIVATE error"))
  end)
end)
