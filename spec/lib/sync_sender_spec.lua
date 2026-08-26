local SyncSender = require("storygraph/lib/sync_sender")

describe("SyncSender", function()
  it("routes progress with a stable book id and regression policy", function()
    local received
    local sender = SyncSender:new {
      api = {
        updatePage = function(_, ...)
          received = { ... }
          return { id = "book-1" }
        end,
      },
    }

    local success = sender:send {
      kind = "progress",
      book_id = "book-1",
      payload = {
        value = 42,
        update_type = "percentage",
        allow_regression = false,
      },
    }

    assert.is_true(success)
    assert.are.equal("book-1_read", received[1])
    assert.are.equal(42, received[2])
    assert.is_true(received[5].skip_behind)
  end)

  it("allows an explicitly requested progress regression", function()
    local options
    local sender = SyncSender:new {
      api = {
        updatePage = function(_, _, _, _, _, value)
          options = value
          return {}
        end,
      },
    }

    assert.is_true(sender:send {
      kind = "progress",
      book_id = "book-1",
      payload = { value = 20, allow_regression = true },
    })
    assert.is_false(options.skip_behind)
  end)

  it("routes ordered status operations", function()
    local received
    local sender = SyncSender:new {
      api = {
        updateUserBook = function(_, book_id, status_id)
          received = { book_id, status_id }
          return {}
        end,
      },
    }

    assert.is_true(sender:send {
      kind = "status",
      book_id = "book-1",
      payload = { status_id = 4 },
    })
    assert.are.same({ "book-1", 4 }, received)
  end)

  it("copies note payloads before adding the stable book id", function()
    local received
    local payload = { entry = "private", date = { year = 2026 } }
    local sender = SyncSender:new {
      api = {
        createJournalEntry = function(_, note)
          received = note
          return {}
        end,
      },
    }

    assert.is_true(sender:send {
      kind = "note",
      book_id = "book-1",
      payload = payload,
    })
    assert.are.equal("book-1", received.book_id)
    assert.is_nil(payload.book_id)
    assert.are_not.equal(payload.date, received.date)
  end)

  it("retains operations when the API does not confirm success", function()
    local sender = SyncSender:new {
      api = { updateUserBook = function() return nil end },
    }

    local success, result, reason = sender:send {
      kind = "status",
      book_id = "book-1",
      payload = { status_id = 3 },
    }
    assert.is_false(success)
    assert.is_nil(result)
    assert.are.equal("remote_error", reason)
  end)
end)
