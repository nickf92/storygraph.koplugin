local loadApp = require("spec/support/load_app")
local SyncQueue = require("storygraph/lib/sync_queue")
local PageMapper = require("storygraph/lib/page_mapper")

describe("Automatic progress thresholds", function()
  local app

  before_each(function()
    app = loadApp {
      ["ui/network/manager"] = { isConnected = function() return false end },
    }
    app.state = {
      page = 199,
      latest_page = 199,
      book_status = { status_id = 2, percent_finished = 15, last_reached_pages = 150 },
    }
    app.ui = { document = { file = "book.epub", getPageCount = function() return 1000 end } }
    app.settings = {
      pages = function() return 1000 end,
      trackByTime = function() return false end,
      trackByProgress = function() return true end,
      trackByPages = function() return false end,
      trackPercentageInterval = function() return 5 end,
      trackPageStep = function() return 10 end,
      syncByRemotePages = function() return true end,
      fileSyncEnabled = function() return true end,
      readBookSetting = function(_, _, key)
        if key == "book_id" then return "edition" end
      end,
    }
    app.page_mapper = PageMapper:new { state = app.state, ui = app.ui }
    app.sync_queue = SyncQueue:new()
    app._syncQueueCallbacks = {}
    app.background_sync = { request = function() return false, "wifi_disabled" end }
  end)

  it("queues the 20 percent threshold offline even when both positions round to 20", function()
    for page = 200, 220 do app:pageUpdateEvent(page) end
    local pending = app.sync_queue:list()
    assert.are.equal(1, #pending)
    assert.are.equal(200, pending[1].payload.value)
    assert.are.equal("pages", pending[1].payload.update_type)
  end)

  it("also queues percentage payloads when rounded percentages are equal", function()
    app.settings.syncByRemotePages = function() return false end
    app:pageUpdateEvent(200)
    local pending = app.sync_queue:list()
    assert.are.equal(1, #pending)
    assert.are.equal(20, pending[1].payload.value)
    assert.are.equal("percentage", pending[1].payload.update_type)
  end)

  it("queues page thresholds within the same rounded percentage", function()
    app.settings.trackByProgress = function() return false end
    app.settings.trackByPages = function() return true end
    app:pageUpdateEvent(200)
    assert.are.equal(1, app.sync_queue:count())
  end)

  it("does not queue a threshold crossed backwards", function()
    app.state.page = 200
    app:pageUpdateEvent(199)
    assert.are.equal(0, app.sync_queue:count())
  end)

  it("does not queue progress before the next threshold", function()
    app.state.page = 200
    for page = 201, 220 do app:pageUpdateEvent(page) end
    assert.are.equal(0, app.sync_queue:count())
  end)

  it("does not queue a threshold behind remote progress", function()
    app.state.book_status.percent_finished = 25
    app:pageUpdateEvent(200)
    assert.are.equal(0, app.sync_queue:count())
  end)
end)
