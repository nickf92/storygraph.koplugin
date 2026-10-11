local loadApp = require("spec/support/load_app")
local SyncQueue = require("storygraph/lib/sync_queue")
local SyncDispatcher = require("storygraph/lib/sync_dispatcher")

describe("Last confirmed progress synchronization", function()
  local app, books, operation
  before_each(function()
    books = { ["book.epub"] = { book_id = "edition", pages = 200 } }
    app = loadApp()
    app.ui = {}
    app._syncQueueCallbacks = {}
    app.settings = {
      readBookSetting = function(_, filename, key) return books[filename][key] end,
      updateBookSetting = function(_, filename, values)
        for key, value in pairs(values) do books[filename][key] = value end
      end,
    }
    operation = { id = "op", document = "book.epub", book_id = "edition",
      kind = "progress", payload = { value = 42, update_type = "percentage" } }
  end)

  it("persists percent and confirmation time for a document no longer open", function()
    local before = os.time()
    app:_onQueuedOperationSuccess(operation, { _storygraph_refresh = true })
    local saved = books["book.epub"].last_progress_sync
    assert.are.equal(42, saved.percent)
    assert.are.equal("edition", saved.book_id)
    assert.is_true(saved.at >= before and saved.at <= os.time())
  end)

  it("converts edition pages to a percentage", function()
    operation.payload = { value = 85, update_type = "pages" }
    app:_onQueuedOperationSuccess(operation, {})
    assert.are.equal(42.5, books["book.epub"].last_progress_sync.percent)
  end)

  it("uses observed progress when a lost-response reconciliation finds a higher value", function()
    app:_onQueuedOperationSuccess(operation, { id = "edition", last_reached_percent = 60 })
    assert.are.equal(60, books["book.epub"].last_progress_sync.percent)
  end)

  it("records progress submitted with a note, but ignores notes without progress", function()
    operation.kind = "note"
    operation.payload = { entry = "Note", progress = 50, progress_type = "pages" }
    app:_onQueuedOperationSuccess(operation, {})
    local saved = books["book.epub"].last_progress_sync
    assert.are.equal(25, saved.percent)
    operation.payload.progress = nil
    app:_onQueuedOperationSuccess(operation, {})
    assert.are.equal(saved, books["book.epub"].last_progress_sync)
  end)

  it("does not invent percentages without edition page counts", function()
    books["book.epub"].pages = nil
    operation.payload = { value = 85, update_type = "pages" }
    app:_onQueuedOperationSuccess(operation, {})
    assert.is_nil(books["book.epub"].last_progress_sync)
  end)

  it("does not overwrite a previous sync for skipped updates or an old edition", function()
    local previous = { book_id = "edition", percent = 35, at = 100 }
    books["book.epub"].last_progress_sync = previous
    app:_onQueuedOperationSuccess(operation, { _storygraph_skipped = true })
    assert.are.equal(previous, books["book.epub"].last_progress_sync)
    books["book.epub"].book_id = "new-edition"
    app:_onQueuedOperationSuccess(operation, {})
    assert.are.equal(previous, books["book.epub"].last_progress_sync)
  end)

  it("records a queued delivery only after it succeeds", function()
    local queue = SyncQueue:new()
    queue:enqueue(operation)
    local success = false
    local dispatcher = SyncDispatcher:new {
      queue = queue, is_connected = function() return true end,
      send = function() return success, {} end,
      on_success = function(op, result) app:_onQueuedOperationSuccess(op, result) end,
    }
    dispatcher:drainOne()
    assert.is_nil(books["book.epub"].last_progress_sync)
    queue:retryOperation(queue:list()[1].id)
    success = true
    dispatcher:drainOne()
    assert.are.equal(42, books["book.epub"].last_progress_sync.percent)
  end)
end)
