local SyncDispatcher = require("storygraph/lib/sync_dispatcher")
local SyncQueue = require("storygraph/lib/sync_queue")
local SyncSender = require("storygraph/lib/sync_sender")

local function memoryStorage()
  local storage = { data = {} }
  function storage:readSetting(key) return self.data[key] end
  function storage:saveSetting(key, value) self.data[key] = value end
  function storage:flush() end
  return storage
end

local function queuedProgress(queue)
  return queue:enqueue {
    document = "book.epub",
    book_id = "book-1",
    kind = "progress",
    payload = { value = 40, update_type = "percentage" },
  }
end

describe("SyncDispatcher", function()
  it("does not call the sender while offline", function()
    local queue = SyncQueue:new { storage = memoryStorage() }
    queuedProgress(queue)
    local calls = 0
    local dispatcher = SyncDispatcher:new {
      queue = queue,
      is_connected = function() return false end,
      send = function() calls = calls + 1 end,
    }

    local success, reason = dispatcher:drainOne()
    assert.is_false(success)
    assert.are.equal("offline", reason)
    assert.are.equal(0, calls)
    assert.are.equal(1, queue:count())
  end)

  it("removes exactly one operation after confirmed success", function()
    local queue = SyncQueue:new { storage = memoryStorage() }
    queuedProgress(queue)
    queue:enqueue {
      document = "book.epub",
      book_id = "book-1",
      kind = "status",
      payload = { status_id = 3 },
    }
    local completed
    local dispatcher = SyncDispatcher:new {
      queue = queue,
      is_connected = function() return true end,
      send = function(operation)
        return true, { remote_id = operation.book_id }
      end,
      on_success = function(operation, result)
        completed = { operation = operation, result = result }
      end,
    }

    local success, reason = dispatcher:drainOne()
    assert.is_true(success)
    assert.are.equal("sent", reason)
    assert.are.equal("progress", completed.operation.kind)
    assert.are.equal("book-1", completed.result.remote_id)
    assert.are.equal(1, queue:count())
    assert.are.equal("status", queue:list()[1].kind)
  end)

  it("retains the operation and stops after a send failure", function()
    local queue = SyncQueue:new { storage = memoryStorage() }
    queuedProgress(queue)
    local failed
    local dispatcher = SyncDispatcher:new {
      queue = queue,
      is_connected = function() return true end,
      send = function() return false, nil, "server_error" end,
      on_failure = function(operation, reason)
        failed = { operation = operation, reason = reason }
      end,
    }

    local success, reason = dispatcher:drainOne()
    assert.is_false(success)
    assert.are.equal("server_error", reason)
    assert.are.equal("progress", failed.operation.kind)
    assert.are.equal(1, queue:count())
  end)

  it("retains progress when StoryGraph leaves the edition as to-read", function()
    local queue = SyncQueue:new { storage = memoryStorage() }
    queuedProgress(queue)
    local sender = SyncSender:new {
      api = {
        updatePage = function()
          return { status_id = 1, last_reached_percent = 0 }
        end,
      },
    }
    local dispatcher = SyncDispatcher:new {
      queue = queue,
      is_connected = function() return true end,
      send = function(operation) return sender:send(operation) end,
    }

    local success, reason = dispatcher:drainOne()

    assert.is_false(success)
    assert.are.equal("not_reading", reason)
    assert.are.equal(1, queue:count())
  end)

  it("sends an explicit reading transition before retained progress", function()
    local queue = SyncQueue:new { storage = memoryStorage() }
    queuedProgress(queue)
    queue:enqueue {
      document = "book.epub",
      book_id = "book-1",
      kind = "status",
      priority = "before_progress",
      payload = { status_id = 2 },
    }
    local sent = {}
    local sender = SyncSender:new {
      api = {
        updateUserBook = function()
          sent[#sent + 1] = "status"
          return { status_id = 2 }
        end,
        updatePage = function()
          sent[#sent + 1] = "progress"
          return { status_id = 2, last_reached_percent = 40 }
        end,
      },
    }
    local dispatcher = SyncDispatcher:new {
      queue = queue,
      is_connected = function() return true end,
      send = function(operation) return sender:send(operation) end,
    }

    assert.is_true(dispatcher:drainOne())
    assert.is_true(dispatcher:drainOne())
    assert.are.same({ "status", "progress" }, sent)
    assert.are.equal(0, queue:count())
  end)

  it("retries a retained operation on a later drain", function()
    local queue = SyncQueue:new { storage = memoryStorage() }
    queuedProgress(queue)
    local attempts = 0
    local dispatcher = SyncDispatcher:new {
      queue = queue,
      is_connected = function() return true end,
      send = function()
        attempts = attempts + 1
        if attempts == 1 then return false, nil, "timeout" end
        return true, { id = "book-1" }
      end,
    }

    assert.is_false(dispatcher:drainOne())
    assert.are.equal(1, queue:count())
    assert.is_true(dispatcher:drainOne())
    assert.are.equal(0, queue:count())
    assert.are.equal(2, attempts)
  end)

  it("continues after failed progress is superseded by a newer value", function()
    local queue = SyncQueue:new { storage = memoryStorage() }
    queuedProgress(queue)
    local attempts = 0
    local dispatcher
    dispatcher = SyncDispatcher:new {
      queue = queue,
      is_connected = function() return true end,
      send = function()
        attempts = attempts + 1
        if attempts == 1 then
          queue:enqueue {
            document = "book.epub",
            book_id = "book-1",
            kind = "progress",
            payload = { value = 50, update_type = "percentage" },
          }
          return false, nil, "timeout"
        end
        return true, {}
      end,
    }

    local success, reason = dispatcher:drainOne()
    assert.is_true(success)
    assert.are.equal("superseded", reason)
    assert.are.equal(1, queue:count())
    assert.is_true(dispatcher:drainOne())
    assert.are.equal(0, queue:count())
  end)

  it("preserves FIFO order across successful drains", function()
    local queue = SyncQueue:new { storage = memoryStorage() }
    queue:enqueue {
      document = "book.epub",
      book_id = "book-1",
      kind = "note",
      payload = { entry = "first" },
    }
    queue:enqueue {
      document = "book.epub",
      book_id = "book-1",
      kind = "status",
      payload = { status_id = 3 },
    }
    local sent = {}
    local dispatcher = SyncDispatcher:new {
      queue = queue,
      is_connected = function() return true end,
      send = function(operation)
        table.insert(sent, operation.kind)
        return true, {}
      end,
    }

    assert.is_true(dispatcher:drainOne())
    assert.is_true(dispatcher:drainOne())
    assert.are.same({ "note", "status" }, sent)
  end)

  it("turns sender exceptions into retained failures", function()
    local queue = SyncQueue:new { storage = memoryStorage() }
    queuedProgress(queue)
    local dispatcher = SyncDispatcher:new {
      queue = queue,
      is_connected = function() return true end,
      send = function() error("unexpected") end,
    }

    local success, reason = dispatcher:drainOne()
    assert.is_false(success)
    assert.matches("unexpected", reason)
    assert.are.equal(1, queue:count())
    assert.is_false(dispatcher.busy)
  end)

  it("does not report remote success when queue deletion cannot persist", function()
    local storage = memoryStorage()
    local queue = SyncQueue:new { storage = storage }
    queuedProgress(queue)
    function storage:flush() error("read only") end
    local success_calls = 0
    local dispatcher = SyncDispatcher:new {
      queue = queue,
      is_connected = function() return true end,
      send = function() return true, {} end,
      on_success = function() success_calls = success_calls + 1 end,
    }

    local success, reason = dispatcher:drainOne()
    assert.is_false(success)
    assert.are.equal("persist_failed", reason)
    assert.are.equal(0, success_calls)
    assert.are.equal(1, queue:count())
  end)

  it("reports an empty connected queue without invoking the sender", function()
    local calls = 0
    local dispatcher = SyncDispatcher:new {
      queue = SyncQueue:new { storage = memoryStorage() },
      is_connected = function() return true end,
      send = function() calls = calls + 1 end,
    }

    local success, reason = dispatcher:drainOne()
    assert.is_true(success)
    assert.are.equal("empty", reason)
    assert.are.equal(0, calls)
  end)

  it("does not undo a confirmed send when a UI callback fails", function()
    local queue = SyncQueue:new { storage = memoryStorage() }
    queuedProgress(queue)
    local dispatcher = SyncDispatcher:new {
      queue = queue,
      is_connected = function() return true end,
      send = function() return true, {} end,
      on_success = function() error("closed document") end,
    }

    local success, reason = dispatcher:drainOne()
    assert.is_true(success)
    assert.are.equal("sent", reason)
    assert.are.equal(0, queue:count())
    assert.is_false(dispatcher.busy)
  end)
end)
