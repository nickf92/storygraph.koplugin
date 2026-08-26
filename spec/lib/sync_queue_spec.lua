local SyncQueue = require("storygraph/lib/sync_queue")

local function memoryStorage(initial)
  local storage = {
    data = initial or {},
    flush_count = 0,
  }

  function storage:readSetting(key)
    return self.data[key]
  end

  function storage:saveSetting(key, value)
    self.data[key] = value
  end

  function storage:flush()
    self.flush_count = self.flush_count + 1
  end

  return storage
end

local function progress(document, value)
  return {
    document = document,
    book_id = "book-1",
    kind = "progress",
    payload = { value = value, update_type = "percentage" },
  }
end

describe("SyncQueue", function()
  it("persists operations and restores them after reconstruction", function()
    local storage = memoryStorage()
    local queue = SyncQueue:new { storage = storage }

    assert.is_truthy(queue:enqueue(progress("book.epub", 25)))

    local restored = SyncQueue:new { storage = storage }
    assert.are.equal(1, restored:count())
    assert.are.equal(25, restored:list()[1].payload.value)
    assert.are.equal(1, storage.flush_count)
  end)

  it("keeps only the latest pending progress for each document", function()
    local queue = SyncQueue:new { storage = memoryStorage() }

    local first = queue:enqueue(progress("book-a.epub", 10))
    local second, err, replaced_id = queue:enqueue(progress("book-a.epub", 20))
    queue:enqueue(progress("book-b.epub", 30))

    assert.is_nil(err)
    assert.are.equal(first.id, replaced_id)
    assert.are.equal(2, queue:count())
    assert.are.equal(second.id, queue:list()[1].id)
    assert.are.equal(20, queue:list()[1].payload.value)
    assert.are.equal(30, queue:list()[2].payload.value)
  end)

  it("does not let completion of active progress remove a newer value", function()
    local queue = SyncQueue:new { storage = memoryStorage() }
    queue:enqueue(progress("book.epub", 10))

    local active = queue:start()
    queue:enqueue(progress("book.epub", 20))
    assert.are.equal(2, queue:count())

    assert.is_true(queue:finish(active.id, true))
    assert.are.equal(1, queue:count())
    assert.are.equal(20, queue:list()[1].payload.value)
  end)

  it("drops failed progress when a newer pending value supersedes it", function()
    local queue = SyncQueue:new { storage = memoryStorage() }
    queue:enqueue(progress("book.epub", 10))
    local active = queue:start()
    queue:enqueue(progress("book.epub", 20))

    local completed, reason = queue:finish(active.id, false)
    assert.is_true(completed)
    assert.are.equal("superseded", reason)
    assert.are.equal(1, queue:count())
    assert.are.equal(20, queue:list()[1].payload.value)
  end)

  it("recovers an in-flight operation after restart", function()
    local storage = memoryStorage()
    local queue = SyncQueue:new { storage = storage }
    local queued = queue:enqueue(progress("book.epub", 10))
    assert.are.equal(queued.id, queue:start().id)

    local restored = SyncQueue:new { storage = storage }
    assert.are.equal(queued.id, restored:start().id)
  end)

  it("retains an operation after a failed send", function()
    local queue = SyncQueue:new { storage = memoryStorage() }
    queue:enqueue(progress("book.epub", 10))

    local active = queue:start()
    assert.is_false(queue:finish(active.id, false))
    assert.are.equal(1, queue:count())
    assert.are.equal(active.id, queue:start().id)
  end)

  it("removes an operation only after successful persistence", function()
    local storage = memoryStorage()
    local queue = SyncQueue:new { storage = storage }
    queue:enqueue(progress("book.epub", 10))
    local active = queue:start()

    function storage:flush()
      error("disk full")
    end

    local success, err = queue:finish(active.id, true)
    assert.is_false(success)
    assert.are.equal("persist_failed", err)
    assert.are.equal(1, queue:count())
    assert.are.equal(1, SyncQueue:new { storage = storage }:count())
  end)

  it("rolls back a new operation when persistence fails", function()
    local storage = memoryStorage()
    function storage:flush() error("disk full") end
    local queue = SyncQueue:new { storage = storage }

    local operation, err = queue:enqueue(progress("book.epub", 10))
    assert.is_nil(operation)
    assert.are.equal("persist_failed", err)
    assert.are.equal(0, queue:count())
    assert.are.equal(0, SyncQueue:new { storage = storage }:count())
  end)

  it("does not mutate previously persisted state when saveSetting fails", function()
    local storage = memoryStorage()
    local queue = SyncQueue:new { storage = storage }
    queue:enqueue(progress("book-a.epub", 10))
    function storage:saveSetting() error("read only") end

    local operation, err = queue:enqueue(progress("book-b.epub", 20))
    assert.is_nil(operation)
    assert.are.equal("persist_failed", err)
    assert.are.equal(1, queue:count())
    assert.are.equal(1, SyncQueue:new { storage = storage }:count())
  end)

  it("preserves status and note ordering while coalescing progress", function()
    local queue = SyncQueue:new { storage = memoryStorage() }
    queue:enqueue(progress("book.epub", 10))
    queue:enqueue {
      document = "book.epub",
      book_id = "book-1",
      kind = "note",
      payload = { entry = "A note", progress = 12 },
    }
    queue:enqueue(progress("book.epub", 20))
    queue:enqueue {
      document = "book.epub",
      book_id = "book-1",
      kind = "status",
      payload = { status_id = 3 },
    }

    local operations = queue:list()
    assert.are.equal(3, #operations)
    assert.are.equal("note", operations[1].kind)
    assert.are.equal("progress", operations[2].kind)
    assert.are.equal(20, operations[2].payload.value)
    assert.are.equal("status", operations[3].kind)
  end)

  it("deduplicates only consecutive identical status operations", function()
    local storage = memoryStorage()
    local queue = SyncQueue:new { storage = storage }
    local status = {
      document = "book.epub",
      book_id = "book-1",
      kind = "status",
      payload = { status_id = 4 },
    }

    local first = queue:enqueue(status)
    local duplicate = queue:enqueue(status)
    queue:enqueue {
      document = "book.epub",
      book_id = "book-1",
      kind = "note",
      payload = { entry = "paused here" },
    }
    queue:enqueue(status)

    assert.are.equal(first.id, duplicate.id)
    assert.are.equal(3, queue:count())
    assert.are.equal(3, storage.flush_count)
  end)

  it("does not append a duplicate of an identical active status", function()
    local queue = SyncQueue:new { storage = memoryStorage() }
    local status = {
      document = "book.epub",
      book_id = "book-1",
      kind = "status",
      payload = { status_id = 4 },
    }
    local first = queue:enqueue(status)
    queue:start()
    local duplicate = queue:enqueue(status)

    assert.are.equal(first.id, duplicate.id)
    assert.are.equal(1, queue:count())
  end)

  it("allows only one active operation", function()
    local queue = SyncQueue:new { storage = memoryStorage() }
    queue:enqueue(progress("book-a.epub", 10))
    queue:enqueue(progress("book-b.epub", 20))

    local first = queue:start()
    assert.is_not_nil(first)
    assert.is_nil(queue:start())
    queue:finish(first.id, false)
    assert.are.equal(first.id, queue:start().id)
  end)

  it("rejects invalid operations without writing storage", function()
    local storage = memoryStorage()
    local queue = SyncQueue:new { storage = storage }

    local operation, err = queue:enqueue { kind = "progress", payload = {} }
    assert.is_nil(operation)
    assert.are.equal("invalid_operation", err)
    assert.are.equal(0, storage.flush_count)
  end)

  it("refuses to overwrite storage after a load failure", function()
    local writes = 0
    local storage = {}
    function storage:readSetting() error("corrupt file") end
    function storage:saveSetting() writes = writes + 1 end
    function storage:flush() end
    local queue = SyncQueue:new { storage = storage }

    local operation, err = queue:enqueue(progress("book.epub", 10))
    assert.is_nil(operation)
    assert.are.equal("persist_failed", err)
    assert.are.equal(0, writes)
    assert.are.equal(0, queue:count())
  end)

  it("does not overwrite a queue created by a newer schema", function()
    local writes = 0
    local storage = memoryStorage {
      sync_queue = { version = 999, next_id = 2, operations = {} },
    }
    function storage:saveSetting() writes = writes + 1 end
    local queue = SyncQueue:new { storage = storage }

    local operation, err = queue:enqueue(progress("book.epub", 10))
    assert.is_nil(operation)
    assert.are.equal("persist_failed", err)
    assert.are.equal(0, writes)
  end)

  it("enforces the operation limit without silently evicting events", function()
    local queue = SyncQueue:new {
      storage = memoryStorage(),
      max_operations = 2,
    }
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
      payload = { status_id = 4 },
    }

    local operation, err = queue:enqueue {
      document = "book.epub",
      book_id = "book-1",
      kind = "note",
      payload = { entry = "second" },
    }
    assert.is_nil(operation)
    assert.are.equal("queue_full", err)
    assert.are.equal(2, queue:count())
  end)

  it("enforces a per-document limit without blocking another document", function()
    local queue = SyncQueue:new {
      storage = memoryStorage(),
      max_operations = 10,
      max_operations_per_document = 1,
    }
    queue:enqueue {
      document = "book-a.epub",
      book_id = "book-a",
      kind = "note",
      payload = { entry = "first" },
    }

    local rejected, err = queue:enqueue {
      document = "book-a.epub",
      book_id = "book-a",
      kind = "note",
      payload = { entry = "second" },
    }
    local accepted = queue:enqueue {
      document = "book-b.epub",
      book_id = "book-b",
      kind = "note",
      payload = { entry = "other book" },
    }

    assert.is_nil(rejected)
    assert.are.equal("queue_full", err)
    assert.is_truthy(accepted)
    assert.are.equal(2, queue:count())
  end)

  it("allows progress replacement when the queue is at its operation limit", function()
    local queue = SyncQueue:new {
      storage = memoryStorage(),
      max_operations = 1,
    }
    queue:enqueue(progress("book.epub", 10))

    assert.is_truthy(queue:enqueue(progress("book.epub", 20)))
    assert.are.equal(1, queue:count())
    assert.are.equal(20, queue:list()[1].payload.value)
  end)

  it("enforces the serialized-size estimate", function()
    local queue = SyncQueue:new {
      storage = memoryStorage(),
      max_bytes = 300,
    }

    local operation, err = queue:enqueue {
      document = "book.epub",
      book_id = "book-1",
      kind = "note",
      payload = { entry = string.rep("x", 1000) },
    }
    assert.is_nil(operation)
    assert.are.equal("queue_full", err)
  end)

  it("removes matching inactive operations and persists the change", function()
    local storage = memoryStorage()
    local queue = SyncQueue:new { storage = storage }
    queue:enqueue(progress("book-a.epub", 10))
    queue:enqueue(progress("book-b.epub", 20))

    local removed = queue:removeWhere(function(operation)
      return operation.document == "book-a.epub" and operation.kind == "progress"
    end)

    assert.are.equal(1, removed)
    assert.are.equal(1, queue:count())
    assert.are.equal("book-b.epub", queue:list()[1].document)
    assert.are.equal(3, storage.flush_count)
  end)
end)
