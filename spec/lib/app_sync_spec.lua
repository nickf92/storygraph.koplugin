local loadApp = require("spec/support/load_app")
local SyncQueue = require("storygraph/lib/sync_queue")
local SyncDispatcher = require("storygraph/lib/sync_dispatcher")

describe("Application sync authorization", function()
  local app, queue, jobs, sent

  before_each(function()
    jobs, sent = {}, 0
    app = loadApp {
      ["ui/network/manager"] = { isConnected = function() return true end },
      ["ui/uimanager"] = { nextTick = function(_, job) jobs[#jobs + 1] = job end },
      ["ui/trapper"] = { wrap = function(_, job) job() end },
    }
    app.settings = { readSetting = function() return false end }
    queue = SyncQueue:new()
    app.sync_queue = queue
    for _, book in ipairs({ "a", "b" }) do
      queue:enqueue { document = book, book_id = book, kind = "note", payload = { entry = book } }
    end
    app.sync_dispatcher = SyncDispatcher:new {
      queue = queue,
      is_connected = function() return true end,
      send = function() sent = sent + 1; return true end,
    }
  end)

  it("retains pending operations and refuses scheduling while disabled", function()
    app.enabled = false
    assert.is_false(app:_requestSyncQueueFlush())
    assert.is_false(app:_drainSyncQueueNow())
    assert.are.equal(0, #jobs)
    assert.are.equal(0, sent)
    assert.are.equal(2, queue:count())
  end)

  it("checks authorization again when a scheduled flush runs", function()
    assert.is_true(app:_requestSyncQueueFlush())
    app.enabled = false
    jobs[1]()
    assert.are.equal(0, sent)
    assert.are.equal(2, queue:count())
  end)

  it("stops between sends if a version check disables the app", function()
    app.sync_dispatcher.send = function()
      sent = sent + 1
      app.enabled = false
      return true
    end
    app:_drainSyncQueueNow()
    assert.are.equal(1, sent)
    assert.are.equal(1, queue:count())
  end)

  it("honors the explicit ignore-version-block setting", function()
    app.enabled = false
    app.settings.readSetting = function(_, key) return key == "ignore_version_block" end
    assert.is_true(app:_requestSyncQueueFlush())
    jobs[1]()
    assert.are.equal(2, sent)
    assert.are.equal(0, queue:count())
  end)
end)
