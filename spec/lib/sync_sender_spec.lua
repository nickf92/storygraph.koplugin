local SyncSender = require("storygraph/lib/sync_sender")

describe("SyncSender", function()
  it("routes progress with a stable book id and regression policy", function()
    local received
    local sender = SyncSender:new {
      api = {
        updatePage = function(_, ...)
          received = { ... }
          return {
            id = "book-1",
            status_id = 2,
            last_reached_percent = 42,
          }
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
          return {
            status_id = 2,
            last_reached_percent = 20,
          }
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

  it("retains progress when the remote edition is not currently reading", function()
    local remote = { status_id = 1, last_reached_pages = 0 }
    local sender = SyncSender:new {
      api = { updatePage = function() return remote end },
    }

    local success, result, reason = sender:send {
      kind = "progress",
      book_id = "book-1",
      payload = { value = 52, update_type = "pages", allow_regression = false },
    }

    assert.is_false(success)
    assert.are.equal(remote, result)
    assert.are.equal("not_reading", reason)
  end)

  it("retains progress when the remote value does not confirm the update", function()
    local sender = SyncSender:new {
      api = {
        updatePage = function()
          return { status_id = 2, last_reached_pages = 39 }
        end,
      },
    }

    local success, _, reason = sender:send {
      kind = "progress",
      book_id = "book-1",
      payload = { value = 52, update_type = "pages", allow_regression = false },
    }

    assert.is_false(success)
    assert.are.equal("progress_unconfirmed", reason)
  end)

  it("requires exact confirmation for an explicit regression", function()
    local sender = SyncSender:new {
      api = {
        updatePage = function()
          return { status_id = 2, last_reached_percent = 30 }
        end,
      },
    }

    local success, _, reason = sender:send {
      kind = "progress",
      book_id = "book-1",
      payload = { value = 20, update_type = "percentage", allow_regression = true },
    }

    assert.is_false(success)
    assert.are.equal("progress_unconfirmed", reason)
  end)

  it("accepts progress already confirmed at a newer remote value", function()
    local sender = SyncSender:new {
      api = {
        updatePage = function()
          return { status_id = 2, last_reached_pages = 60 }
        end,
      },
    }

    assert.is_true(sender:send {
      kind = "progress",
      book_id = "book-1",
      payload = { value = 52, update_type = "pages", allow_regression = false },
    })
  end)

  it("accepts an update deliberately skipped because remote progress is ahead", function()
    local sender = SyncSender:new {
      api = {
        updatePage = function()
          return { _storygraph_skipped = true, last_reached_pages = 60 }
        end,
      },
    }

    assert.is_true(sender:send {
      kind = "progress",
      book_id = "book-1",
      payload = { value = 52, update_type = "pages", allow_regression = false },
    })
  end)

  it("routes ordered status operations", function()
    local received
    local sender = SyncSender:new {
      api = {
        updateUserBook = function(_, book_id, status_id)
          received = { book_id, status_id }
          return { status_id = status_id }
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
          return {}, { status = "confirmed" }
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
