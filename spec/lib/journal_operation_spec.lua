local JournalOperation = require("storygraph/lib/journal_operation")

describe("JournalOperation", function()
  it("turns an empty journal entry into coalescible progress", function()
    local operation = JournalOperation:build("book.epub", {
      book_id = "book-1",
      entry = "",
      progress = 42,
      progress_type = "percentage",
      local_page = 100,
    })

    assert.are.equal("progress", operation.kind)
    assert.are.equal(42, operation.payload.value)
    assert.is_true(operation.payload.allow_regression)
  end)

  it("keeps authored notes as distinct operations with their date", function()
    local date = { year = 2026, month = 8, day = 26 }
    local operation = JournalOperation:build("book.epub", {
      book_id = "book-1",
      entry = "A note",
      progress = 42,
      progress_type = "percentage",
      date = date,
    })

    assert.are.equal("note", operation.kind)
    assert.are.equal("A note", operation.payload.entry)
    assert.are.equal(date, operation.payload.date)
  end)

  it("rejects missing document identity", function()
    assert.is_nil(JournalOperation:build(nil, {}))
  end)
end)
