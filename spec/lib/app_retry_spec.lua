local loadApp = require("spec/support/load_app")
local Queue = require("storygraph/lib/sync_queue")
local Dispatcher = require("storygraph/lib/sync_dispatcher")

describe("Application retry lifecycle", function()
  local app, queue, now, connected, ticks, timers, sends, notifications
  before_each(function()
    now, connected, ticks, timers, sends, notifications = 1000, true, {}, {}, {}, 0
    app = loadApp {
      logger = { warn=function() end, info=function() end },
      ["ui/network/manager"] = {isConnected=function() return connected end},
      ["ui/uimanager"] = {
        nextTick=function(_, job) ticks[#ticks+1]=job end,
        scheduleIn=function(_, delay, job) timers[job]=delay end,
        unschedule=function(_, job) timers[job]=nil end,
        show=function() notifications=notifications+1 end,
      },
      ["ui/widget/notification"] = {new=function(_, o) return o end},
      ["ui/trapper"] = {wrap=function(_, job) job() end},
      ["storygraph/lib/scheduler"] = {clear=function() end},
    }
    queue = Queue:new {now=function() return now end, random=function() return 0.5 end}
    app.sync_queue, app._syncQueueCallbacks = queue, {}
    app.settings = {readSetting=function() return false end}
    app.ui, app.state = {}, {}
    app.sync_dispatcher = Dispatcher:new {
      queue=queue, is_connected=function() return connected end,
      send=function(op)
        sends[#sends+1]=op.document
        if op.document == "a" then
          return false, nil, "rate_limited", {status="rejected",category="transient",reason="rate_limited"}
        end
        return true, {}
      end,
      on_failure=function(op, reason) app:_onQueuedOperationFailure(op, reason) end,
    }
    for _, name in ipairs({"a","b"}) do
      queue:enqueue {document=name,book_id=name,kind="progress",payload={value=40}}
    end
  end)

  it("drains independent documents and schedules just the next due retry", function()
    app:_drainSyncQueueNow()
    assert.are.same({"a","b"}, sends)
    assert.are.equal(1, queue:count())
    assert.are.equal(60, timers[app._syncQueueRetryJob])
    now=1060
    app._syncQueueRetryJob()
    ticks[#ticks]()
    assert.are.same({"a","b","a"}, sends)
    assert.are.equal(120, timers[app._syncQueueRetryJob])
  end)

  it("cancels retry wakeups on suspend and preserves the deadline on resume", function()
    app:_drainSyncQueueNow()
    app:onSuspend()
    assert.is_nil(app._syncQueueRetryJob)
    assert.is_false(app:_requestSyncQueueFlush())
    now=1030
    app:onResume()
    ticks[#ticks]()
    assert.are.same({"a","b"}, sends)
    assert.are.equal(30, timers[app._syncQueueRetryJob])
  end)

  it("does not schedule retries while disconnected", function()
    app:_drainSyncQueueNow()
    connected=false
    app:onNetworkDisconnecting()
    app:_scheduleSyncQueueRetry()
    assert.is_nil(app._syncQueueRetryJob)
    assert.is_false(app:_requestSyncQueueFlush())
  end)

  it("unblocks authentication on credential changes without overriding a version block", function()
    queue:blockAuthentication()
    app.enabled=false
    app:onSettingsChanged("session_cookie", "synthetic")
    assert.is_false(queue:isAuthBlocked())
    assert.is_false(app.enabled)
    assert.are.equal(0, #ticks)
  end)
  it("does not repeat an unchanged progress warning on every retry", function()
    app:_onQueuedOperationFailure({id=1,kind="progress"}, "progress_unconfirmed")
    app:_onQueuedOperationFailure({id=1,kind="progress",last_error="progress_unconfirmed"}, "progress_unconfirmed")
    assert.are.equal(1, notifications)
  end)

  it("schedules GET-only note checks through suspend, resume and reconnect", function()
    queue:removeWhere(function() return true end)
    queue:enqueue {document="note.epub", book_id="book-1", kind="note", payload={entry="Synthetic"}}
    local posts, checks = 0, 0
    app.sync_dispatcher.send = function(op, save)
      if op.delivery_state then
        checks=checks+1
      else
        posts=posts+1
        assert.is_true(save {book_id="book-1", before={}, date={year=2026,month=9,day=27},
          progress=40, progress_type="percentage", attempts=0})
      end
      return false, nil, "note_uncertain", {status="uncertain",category="reconciliation",
        reason="note_uncertain",verification_reason="entry_absent"}
    end
    app:_drainSyncQueueNow()
    assert.equals(60, timers[app._syncQueueRetryJob])
    app:onSuspend()
    assert.is_nil(app._syncQueueRetryJob)
    now=1030
    app:onResume(); ticks[#ticks]()
    assert.equals(30, timers[app._syncQueueRetryJob])
    assert.equals(0, checks)
    now=1060; app._syncQueueRetryJob(); ticks[#ticks]()
    assert.equals(1, checks)
    assert.equals(120, timers[app._syncQueueRetryJob])
    connected=false; app:onNetworkDisconnecting()
    assert.is_nil(app._syncQueueRetryJob)
    now=1200
    assert.is_false(app:_requestSyncQueueFlush())
    connected=true; app._networkDisconnecting=false
    assert.is_true(app:_requestSyncQueueFlush()); ticks[#ticks]()
    assert.equals(2, checks)
    assert.equals(1, posts)
    assert.equals(240, timers[app._syncQueueRetryJob])
  end)

end)
