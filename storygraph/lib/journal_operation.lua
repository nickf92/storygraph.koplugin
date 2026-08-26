local JournalOperation = {}

function JournalOperation:build(document, data)
  if type(document) ~= "string" or document == "" or type(data) ~= "table" then
    return nil
  end

  if data.entry == "" then
    return {
      document = document,
      book_id = data.book_id,
      kind = "progress",
      payload = {
        value = data.progress,
        update_type = data.progress_type,
        allow_regression = true,
        local_page = data.local_page,
      },
    }
  end

  return {
    document = document,
    book_id = data.book_id,
    kind = "note",
    payload = data,
  }
end

return JournalOperation
