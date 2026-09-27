local loadApp=require("spec/support/load_app")
local Queue=require("storygraph/lib/sync_queue")
local Background=require("storygraph/lib/background_sync")

describe("Progress capture on an existing connection",function()
  local app, online, flushes, cancelled, now, wifi_calls
  before_each(function()
    online,flushes,cancelled,now,wifi_calls=true,0,0,1000,0
    app=loadApp {
      logger={info=function() end,warn=function() end},
      ["ui/network/manager"]={isConnected=function() return online end},
    }
    app.state={page=20,latest_page=24,progress_dirty=true,read_cache_started=true,
      book_status={id="edition",status_id=2,percent_finished=20,last_reached_pages=20}}
    app.ui={document={file="book.epub",getPageCount=function() return 100 end}}
    app.settings={readSetting=function() return false end, pages=function() return 100 end,
      syncEnabled=function() return true end,syncByRemotePages=function() return true end,
      fileSyncEnabled=function() return true end,
      readBookSetting=function(_,_,key) if key=="book_id" then return "edition" end end}
    app.page_mapper={getRemotePagePercent=function(_,page) return page/100,page end}
    app.sync_queue=Queue:new {now=function() return now end,random=function() return 0.5 end}
    app.sync_dispatcher={busy=false}
    app._syncQueueCallbacks={}
    app._requestSyncQueueFlush=function() flushes=flushes+1; return true end
    app._cancelPageUpdate=function() cancelled=cancelled+1 end
    app._cancelPageUpdateEvent=function() cancelled=cancelled+1 end
    app._notifySyncQueueError=function() end
    app.background_sync=Background:new {
      wifi={withWifi=function() wifi_calls=wifi_calls+1 end},is_connected=function() return online end,
      wifi_enabled=function() return false end,cooldown_seconds=function() return 3600 end,
      request_flush=function() return app:_requestSyncQueueFlush() end,drain_now=function() end,
    }
  end)
  local function queueProgress(value,manual)
    return app.sync_queue:enqueue {document="book.epub",book_id="edition",kind="progress",
      payload={value=value,update_type="pages",local_page=value,allow_regression=manual==true}}
  end

  it("captures sub-threshold progress without enabling Wi-Fi or dispatching twice",function()
    app:onNetworkConnected()
    local op=app.sync_queue:list()[1]
    assert.equals(24,op.payload.value)
    assert.equals(24,op.payload.local_page)
    assert.is_false(op.payload.allow_regression)
    assert.equals(1,flushes); assert.equals(0,wifi_calls)
    assert.equals(2,cancelled)
  end)

  it("coalesces buffered progress and preserves retry deadlines",function()
    queueProgress(21)
    app.sync_queue:finish(app.sync_queue:start().id,false,
      {status="rejected",category="transient",reason="rate_limited",retry_after=120})
    app:onNetworkConnected()
    assert.equals(1,app.sync_queue:count())
    assert.equals(24,app.sync_queue:list()[1].payload.value)
    assert.equals(1120,app.sync_queue:nextAttemptAt())
    assert.is_nil(app.sync_queue:start())
  end)

  it("does not replace equal queued progress on duplicate connection events",function()
    app:onNetworkConnected()
    local original=app.sync_queue:list()[1]
    app:onNetworkConnected()
    assert.same(original,app.sync_queue:list()[1])
    assert.equals(1,app.sync_queue:count())
    assert.equals(0,wifi_calls)
  end)

  it("does not enqueue progress already observed remotely",function()
    app.state.latest_page=20
    app:onNetworkConnected()
    assert.equals(0,app.sync_queue:count())
    assert.is_false(app.state.progress_dirty)
  end)

  it("preserves manually authorized regression and pending notes",function()
    local original=queueProgress(10,true)
    app.sync_queue:enqueue {document="book.epub",book_id="edition",kind="note",payload={entry="Synthetic"}}
    app:onNetworkConnected()
    assert.same(original,app.sync_queue:list()[1])
    assert.equals("note",app.sync_queue:list()[2].kind)
    assert.equals(0,cancelled)
  end)

  it("does not queue a regression behind remote progress",function()
    app.state.latest_page=19
    app:onNetworkConnected()
    assert.equals(0,app.sync_queue:count())
    assert.equals(0,cancelled)
  end)

  it("respects offline, disabled, paused and transition states",function()
    for _, block in ipairs({"offline","disabled","suspended","transition","paused","file_disabled"}) do
      online=block~="offline"; app.enabled=block~="disabled"
      app._syncQueueSuspended=block=="suspended"
      app._editionTransitionInProgress=block=="transition"
      app.settings.fileSyncEnabled=function() return block~="file_disabled" end
      if block=="paused" then app.sync_queue:pauseDocument("book.epub")
      else app.sync_queue:resumeDocument("book.epub") end
      app:_captureConnectedProgress()
      assert.equals(0,app.sync_queue:count())
    end
    assert.equals(0,wifi_calls)
  end)

  it("keeps buffered progress when the local queue cannot save it",function()
    app.sync_queue.storage={saveSetting=function() error("disk full") end}
    app:onNetworkConnected()
    assert.equals(0,app.sync_queue:count())
    assert.equals(0,cancelled)
    assert.is_true(app.state.progress_dirty)
  end)

  it("joins a temporary Wi-Fi session before its owner shuts it down",function()
    app.background_sync.wifi_attempt_pending=true
    app.background_sync.wifi_attempt_consumer="version_check"
    app:onNetworkConnected()
    assert.equals(1,#app.background_sync.wifi_attempt_waiters)
    assert.equals("background_sync",app.background_sync.wifi_attempt_waiters[1].consumer)
    assert.equals(0,flushes)
    assert.equals(0,wifi_calls)
  end)

  it("preserves dirty progress on repeated position notifications",function()
    app.state.process_page_turns=true
    app.pageUpdateEvent=function(self,page) self.state.page=page end
    app:onPosUpdate(nil,24); app:onPosUpdate(nil,24)
    assert.is_true(app.state.progress_dirty)
    app:onNetworkConnected()
    assert.equals(24,app.sync_queue:list()[1].payload.value)
  end)

  it("supports percentage sync without adding a second update",function()
    app.settings.syncByRemotePages=function() return false end
    app:onNetworkConnected(); app:onNetworkConnected()
    assert.equals(1,app.sync_queue:count())
    assert.equals("percentage",app.sync_queue:list()[1].payload.update_type)
  end)
end)
