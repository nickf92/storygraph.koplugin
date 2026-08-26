local ProgressSync = require("storygraph/lib/progress_sync")

describe("ProgressSync", function()
  it("keeps only the latest pending update for each document", function()
    local sync = ProgressSync:new()

    sync:put("book-a.epub", { value = 10 })
    sync:put("book-a.epub", { value = 12 })
    sync:put("book-b.epub", { value = 30 })

    assert.are.equal(12, sync:start("book-a.epub").value)
    assert.are.equal(30, sync:start("book-b.epub").value)
  end)

  it("does not start another update while one is active", function()
    local sync = ProgressSync:new()

    sync:put("book.epub", { value = 10 })
    assert.are.equal(10, sync:start("book.epub").value)

    sync:put("book.epub", { value = 11 })
    assert.is_nil(sync:start("book.epub"))

    local trailing, has_newer = sync:finish("book.epub", true)
    assert.are.equal(11, trailing.value)
    assert.is_true(has_newer)
    assert.are.equal(11, sync:start("book.epub").value)
  end)

  it("restores a failed update unless a newer value is pending", function()
    local sync = ProgressSync:new()

    sync:put("book.epub", { value = 10 })
    sync:start("book.epub")
    local restored, has_newer = sync:finish("book.epub", false)
    assert.are.equal(10, restored.value)
    assert.is_false(has_newer)

    assert.are.equal(10, sync:start("book.epub").value)
    sync:put("book.epub", { value = 12 })
    restored, has_newer = sync:finish("book.epub", false)
    assert.are.equal(12, restored.value)
    assert.is_true(has_newer)
  end)

  it("discards pending and active updates when cleared", function()
    local sync = ProgressSync:new()

    sync:put("book.epub", { value = 10 })
    sync:start("book.epub")
    sync:put("book.epub", { value = 11 })
    sync:clear("book.epub")

    assert.is_false(sync:isActive("book.epub"))
    assert.is_false(sync:hasPending("book.epub"))
  end)
end)
