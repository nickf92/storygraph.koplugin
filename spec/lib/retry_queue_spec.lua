local Queue = require("storygraph/lib/sync_queue")
local Dispatcher = require("storygraph/lib/sync_dispatcher")

local function operation(document, kind)
  return {document=document, book_id=document, kind=kind or "progress", payload={value=40, update_type="percentage"}}
end
local function memory()
  return { readSetting=function(self) return self.data end,
    saveSetting=function(self, _, data) self.data=data end, flush=function() end }
end

describe("Persistent per-operation retry", function()
  local now, disk, queue
  local function restore()
    return Queue:new {storage=disk, now=function() return now end, random=function() return 0.5 end}
  end
  before_each(function() now=1000; disk=memory(); queue=restore() end)

  it("defers the failed document while allowing an independent document", function()
    queue:enqueue(operation("a"))
    queue:enqueue(operation("a", "status"))
    queue:enqueue(operation("b"))
    local op = queue:start()
    queue:finish(op.id, false, {status="rejected",category="transient",reason="rate_limited"})
    assert.are.equal("b", queue:start().document)
    local pending = queue:list()[1]
    assert.are.equal(1, pending.attempt_count)
    assert.are.equal(1060, pending.next_attempt_at)
  end)

  it("preserves the retry deadline across a restart", function()
    queue:enqueue(operation("a"))
    queue:finish(queue:start().id, false, {status="rejected",category="transient",reason="remote_error"})
    queue=restore()
    assert.is_nil(queue:start())
    assert.are.equal(1060, queue:nextAttemptAt())
    now=1060
    assert.are.equal("a", queue:start().document)
  end)

  it("does not reset backoff when new progress replaces the pending value", function()
    queue:enqueue(operation("a"))
    queue:finish(queue:start().id, false, {status="rejected",category="transient",reason="rate_limited"})
    local newer=operation("a"); newer.payload.value=50
    queue:enqueue(newer)
    assert.are.equal(1060, queue:list()[1].next_attempt_at)
    assert.is_nil(queue:start())
  end)

  it("waits for credential changes after authentication fails", function()
    queue:enqueue(operation("a")); queue:enqueue(operation("b"))
    queue:finish(queue:start().id, false, {status="rejected",category="auth",reason="unauthorized"})
    queue=restore()
    now=99999
    assert.is_nil(queue:start())
    assert.is_nil(queue:nextAttemptAt())
    assert.is_true(queue:credentialsChanged())
    assert.are.equal("a", queue:start().document)
  end)

  it("requires explicit reconciliation before retrying an uncertain note", function()
    local pending=operation("a", "note"); pending.payload.entry="Synthetic"
    local added=queue:enqueue(pending)
    queue:finish(queue:start().id, false, {status="uncertain",category="transient",reason="remote_error"})
    queue=restore(); now=99999
    assert.is_nil(queue:start())
    assert.is_nil(queue:retryOperation(added.id))
    assert.is_true(queue:resolveNote(added.id, false))
    assert.is_nil(queue:start().delivery_state)
  end)

  it("removes an uncertain note only after the user confirms it was delivered", function()
    local added=queue:enqueue(operation("a", "note"))
    queue:start() -- crash after marking in flight
    queue=restore()
    assert.is_true(queue:resolveNote(added.id, true))
    assert.are.equal(0, queue:count())
  end)
end)

describe("Retry policy boundaries", function()
  it("honors server Retry-After and caps generated exponential delays", function()
    local Policy=require("storygraph/lib/retry_policy")
    local plan=Policy:plan({attempt_count=20,kind="progress"},
      {status="rejected",category="transient",retry_after=7200},1000,function() return 1 end,60,3600)
    assert.are.equal(8200,plan.next_attempt_at)
    plan=Policy:plan({attempt_count=20,kind="progress"},
      {status="rejected",category="transient"},1000,function() return 1 end,60,3600)
    assert.are.equal(4600,plan.next_attempt_at)
  end)

  it("releases not-reading progress after an explicit reading transition succeeds", function()
    local q=Queue:new()
    q:enqueue(operation("a"))
    q:finish(q:start().id,false,{status="rejected",category="permanent",reason="not_reading"})
    assert.is_nil(q:start())
    q:enqueue {document="a",book_id="a",kind="status",priority="before_progress",payload={status_id=2}}
    local status=q:start()
    assert.are.equal("status",status.kind)
    assert.is_true(q:finish(status.id,true))
    assert.are.equal("progress",q:start().kind)
  end)

  it("does not reorder two documents updating the same remote edition", function()
    local q=Queue:new()
    q:enqueue(operation("a"))
    local other=operation("b");other.book_id="a";q:enqueue(other)
    q:finish(q:start().id,false,{status="rejected",category="permanent",reason="invalid_request"})
    assert.is_nil(q:start())
  end)
end)

describe("Concurrent progress retry", function()
  it("preserves throttling when an in-flight value is superseded", function()
    local q=Queue:new {now=function() return 1000 end,random=function() return 0.5 end}
    q:enqueue(operation("a"))
    local active=q:start()
    local newer=operation("a");newer.payload.value=50
    q:enqueue(newer)
    local ok, reason=q:finish(active.id,false,{status="rejected",category="transient",reason="rate_limited",retry_after=120})
    assert.is_true(ok)
    assert.are.equal("superseded",reason)
    assert.are.equal(1120,q:list()[1].next_attempt_at)
    assert.is_nil(q:start())
  end)
end)
