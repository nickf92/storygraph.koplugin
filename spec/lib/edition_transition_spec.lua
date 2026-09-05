local loadApp = require("spec/support/load_app")
local Queue = require("storygraph/lib/sync_queue")
local Mapper = require("storygraph/lib/page_mapper")

describe("Pending operations during an edition transition", function()
  local app, queue, storage, hardcover, api, saved_book

  before_each(function()
    storage = { data = {} }
    function storage:readSetting(key) return self.data[key] end
    function storage:saveSetting(key, value) self.data[key] = value end
    function storage:flush() end
    queue = Queue:new { storage = storage }
    saved_book = "old"
    api = { findUserBook = function(_, id) return { id = id, status_id = 2 } end }
    local dependencies = {
      gettext = function(text) return text end,
      logger = { info = function() end },
      ["storygraph/lib/hardcover_api"] = api,
      ["storygraph/lib/book"] = require("storygraph/lib/book"),
      ["storygraph/lib/user"] = { getId = function() return "user" end },
    }
    local env = setmetatable({ require = function(name)
      return dependencies[name] or {}
    end }, { __index = _G })
    local Hardcover = setfenv(assert(loadfile("storygraph/lib/hardcover.lua")), env)()
    hardcover = Hardcover:new {
      state = {},
      settings = {
        getLinkedBookId = function() return saved_book end,
        updateBookSetting = function(_, _, settings) saved_book = settings.book_id end,
      },
      relink_document = function(filename, book) return app:_relinkQueuedOperations(filename, book) end,
    }
    app = loadApp {
      ["ui/network/manager"] = { isConnected = function() return false end },
    }
    app.ui = { document = { file = "book.epub", getPageCount = function() return 100 end },
      getCurrentPage = function() return 60 end }
    hardcover.ui = app.ui
    app.state = { latest_page = 55, book_status = {} }
    app.settings = { pages = function() return 200 end, syncByRemotePages = function() return true end }
    app.page_mapper = Mapper:new { ui = app.ui, state = app.state }
    app.sync_queue = queue
    app._syncQueueCallbacks = {}
    app.sync_dispatcher = { busy = false }
    app.dialog_manager = { showError = function() end }
    hardcover.dialog_manager = app.dialog_manager
    hardcover.with_link_change = function(callback) return app:_withEditionTransition(callback) end
    app._notifySyncQueueError = function() end
    queue:enqueue { document = "book.epub", book_id = "old", kind = "progress",
      payload = { value = 180, update_type = "pages", local_page = 90, allow_regression = true } }
    queue:enqueue { document = "book.epub", book_id = "old", kind = "note",
      payload = { entry = "Earlier note", progress = 40, progress_type = "pages", local_page = 20,
        date = { year = 2026, month = 9, day = 5 } } }
    queue:enqueue { document = "other.epub", book_id = "other", kind = "note", payload = { entry = "Other" } }
  end)

  it("migrates queued operations when the user links a different edition", function()
    assert.is_true(hardcover:linkBook { book_id = "new", pages = 400, title = "Book" })
    assert.are.equal("new", saved_book)
    assert.are.equal("new", queue:list()[1].book_id)
    assert.are.equal(240, queue:list()[1].payload.value)
    assert.are.equal("new", queue:list()[2].book_id)
  end)

  it("does not save a new link when the pending operations cannot be saved", function()
    function storage:flush() error("disk full") end
    assert.is_false(hardcover:linkBook { book_id = "new", pages = 400, title = "Book" })
    assert.are.equal("old", saved_book)
    assert.are.equal("old", queue:list()[1].book_id)
  end)

  it("remaps progress from the current document position and notes from their own position", function()
    assert.is_true(app:_relinkQueuedOperations("book.epub", { book_id = "new", pages = 400 }))
    local ops = Queue:new { storage = storage }:list()
    assert.are.equal("new", ops[1].book_id)
    assert.are.equal(240, ops[1].payload.value)
    assert.are.equal(60, ops[1].payload.local_page)
    assert.is_false(ops[1].payload.allow_regression)
    assert.are.equal("new", ops[2].book_id)
    assert.are.equal("new", ops[2].payload.book_id)
    assert.are.equal(80, ops[2].payload.progress)
    assert.are.equal(20, ops[2].payload.local_page)
    assert.are.equal("Earlier note", ops[2].payload.entry)
    assert.are.same({ year = 2026, month = 9, day = 5 }, ops[2].payload.date)
    assert.are.equal("other", ops[3].book_id)
  end)

  it("uses percentages when the destination has no page count", function()
    assert.is_true(app:_relinkQueuedOperations("book.epub", { book_id = "new" }))
    local ops = queue:list()
    assert.are.equal(60, ops[1].payload.value)
    assert.are.equal("percentage", ops[1].payload.update_type)
    assert.are.equal(20, ops[2].payload.progress)
    assert.are.equal("percentage", ops[2].payload.progress_type)
  end)

  it("does not reuse regression permission granted for another edition", function()
    app:_relinkQueuedOperations("book.epub", { book_id = "new", pages = 400 })
    assert.is_false(queue:list()[1].payload.allow_regression)
  end)

  it("keeps the original queue if saving the transition fails", function()
    local before = queue:list()
    function storage:flush() error("disk full") end
    assert.is_false(app:_relinkQueuedOperations("book.epub", { book_id = "new", pages = 400 }))
    assert.are.same(before, queue:list())
  end)

  it("refuses to retarget an operation already being sent", function()
    local before = queue:list()
    queue:start()
    assert.is_false(app:_relinkQueuedOperations("book.epub", { book_id = "new", pages = 400 }))
    assert.are.same(before, queue:list())
  end)
  it("pauses sends across a remote switch and resumes after saving the new link", function()
    api.findEditions = function() return {} end
    api.switchEdition = function()
      assert.is_false(app:_requestSyncQueueFlush())
      assert.is_false(app:_drainSyncQueueNow())
      -- A second process/restart also respects the persisted pause.
      local restored = Queue:new { storage = storage }
      assert.are.equal("other.epub", restored:start().document)
      return true
    end
    local select_edition
    hardcover.dialog_manager.buildSearchDialog = function(_, _, _, _, callback)
      select_edition = callback
    end
    hardcover:showChangeEditionDialog()
    select_edition { book_id = "new", pages = 400, title = "Book" }
    assert.are.equal("new", saved_book)
    assert.are.equal("new", Queue:new { storage = storage }:start().book_id)
    assert.is_false(app._editionTransitionInProgress)
  end)

  it("retains the durable pause after an interrupted switch until linking is retried", function()
    local result = app:_withEditionTransition(function() return false end)
    assert.is_false(result)
    assert.are.equal("other.epub", Queue:new { storage = storage }:start().document)
    assert.is_true(hardcover:linkBook { book_id = "new", pages = 400, title = "Book" })
    assert.are.equal("new", Queue:new { storage = storage }:start().book_id)
  end)

  it("releases the in-memory lock but retains the durable pause after an exception", function()
    local success = pcall(function()
      app:_withEditionTransition(function() error("network failed") end)
    end)
    assert.is_false(success)
    assert.is_false(app._editionTransitionInProgress)
    assert.are.equal("other.epub", Queue:new { storage = storage }:start().document)
  end)

  it("does not start a link change during an in-flight send", function()
    app.sync_dispatcher.busy = true
    local called = false
    assert.is_false(app:_withEditionTransition(function() called = true end))
    assert.is_false(called)
    assert.are.equal("old", queue:start().book_id)
  end)

  it("preserves pending status order and clears obsolete completion callbacks", function()
    local operation = queue:enqueue { document = "book.epub", book_id = "old", kind = "status",
      priority = "before_progress", payload = { status_id = 2 } }
    app._syncQueueCallbacks[operation.id] = function() error("stale callback") end
    app:_relinkQueuedOperations("book.epub", { book_id = "new", pages = 400 })
    local ops = queue:list()
    assert.are.equal("status", ops[1].kind)
    assert.are.equal("new", ops[1].book_id)
    assert.are.equal(2, ops[1].payload.status_id)
    assert.is_nil(app._syncQueueCallbacks[operation.id])
  end)

  it("does not reinterpret operations already targeting the selected edition", function()
    local before = queue:list()
    assert.is_true(app:_relinkQueuedOperations("book.epub", { book_id = "old", pages = 200 }))
    assert.are.same(before, queue:list())
  end)

  it("recovers a legacy note position using source edition pagination", function()
    queue:enqueue { document = "book.epub", book_id = "old", kind = "note",
      payload = { entry = "Legacy", progress = 50, progress_type = "pages" } }
    app:_relinkQueuedOperations("book.epub", { book_id = "new", pages = 400 })
    local note = queue:list()[4].payload
    assert.are.equal(25, note.local_page)
    assert.are.equal(100, note.progress)
  end)

  it("persists the pause before making any remote request", function()
    local called = false
    api.findUserBook = function() called = true; return { id = "new", status_id = 2 } end
    function storage:flush() error("disk full") end
    assert.is_false(hardcover:linkBook { book_id = "new", pages = 400 })
    assert.is_false(called)
  end)

  it("keeps updates paused when migration fails after the remote request", function()
    api.findUserBook = function()
      function storage:flush() error("disk full") end
      return { id = "new", status_id = 2 }
    end
    assert.is_false(hardcover:linkBook { book_id = "new", pages = 400 })
    assert.are.equal("old", saved_book)
    assert.are.equal("other.epub", Queue:new { storage = storage }:start().document)
  end)

  it("keeps updates paused if saving the local link throws", function()
    hardcover.settings.updateBookSetting = function() error("sidecar unavailable") end
    local ok = pcall(function() hardcover:linkBook { book_id = "new", pages = 400 } end)
    assert.is_false(ok)
    assert.are.equal("other.epub", Queue:new { storage = storage }:start().document)
  end)

  it("cancels buffered progress calculated using the previous edition", function()
    local cancelled = false
    app._cancelPageUpdate = function() cancelled = true end
    assert.is_true(hardcover:linkBook { book_id = "new", pages = 400 })
    assert.is_true(cancelled)
  end)

  it("does not link a newly opened document after an edition-switch request yields", function()
    api.findEditions = function() return {} end
    api.switchEdition = function()
      app.ui.document = { file = "different.epub" }
      return true
    end
    local select_edition
    hardcover.dialog_manager.buildSearchDialog = function(_, _, _, _, callback)
      select_edition = callback
    end
    hardcover:showChangeEditionDialog()
    select_edition { book_id = "new", pages = 400 }
    assert.are.equal("old", saved_book)
    assert.are.equal("other.epub", Queue:new { storage = storage }:start().document)
  end)

end)
