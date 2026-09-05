local loadApi = require("spec/support/load_api")
local Sender = require("storygraph/lib/sync_sender")
local function fixture()
  local f = assert(io.open("spec/fixtures/reading.html"))
  local html = f:read("*a"); f:close(); return html
end

describe("StoryGraph HTML and mutation contract", function()

  it("confirms a note without depending on a subsequent refresh", function()
    local api = loadApi()
    local calls = 0
    api.request = function(_, _, method)
      calls = calls + 1
      if calls == 1 then return 200, fixture(), {} end
      if method == "POST" then return 204, "", {} end
      error("a confirmed note must not depend on a refresh")
    end
    local result, outcome = api:createJournalEntry { book_id = "book-1", entry = "Synthetic note", progress = 40 }
    assert.is_truthy(result)
    assert.are.equal("confirmed", outcome.status)
    assert.are.equal(2, calls)
  end)

  it("distinguishes a POST timeout from a rejected request", function()
    local api = loadApi()
    api.request = function(_, _, method)
      if method == "GET" then return 200, fixture(), {} end
      return nil, "timeout"
    end
    local _, outcome = api:createJournalEntry { book_id = "book-1", entry = "Synthetic note" }
    assert.are.equal("uncertain", outcome.status)
  end)

  it("does not accept a status differing from the requested status", function()
    local api = loadApi()
    api.request = function(_, _, method)
      if method == "GET" then return 200, fixture(), {} end
      return 204, "", {}
    end
    local success = Sender:new { api = api }:send {
      kind = "status", book_id = "book-1", payload = { status_id = 3 },
    }
    assert.is_false(success)
  end)
  it("does not create a rereading attempt after authentication or validation rejection", function()
    for _, code in ipairs({401, 422}) do
      local api, posts = loadApi(), 0
      api.request = function(_, _, method)
        if method == "GET" then return 200, fixture(), {} end
        posts = posts + 1
        return code, "", {}
      end
      local _, outcome = api:updateUserBook("book-1", 2)
      assert.are.equal("rejected", outcome.status)
      assert.are.equal(1, posts)
    end
  end)

  it("does not POST a note when the progress form is missing", function()
    local api, posts = loadApi(), 0
    api.request = function(_, _, method)
      if method == "POST" then posts = posts + 1 end
      return 200, '<meta name="csrf-token" content="synthetic">', {}
    end
    local _, outcome = api:createJournalEntry {book_id="book-1",entry="Synthetic"}
    assert.are.equal("invalid_page", outcome.reason)
    assert.are.equal(0, posts)
  end)

  it("recognizes a rendered login page even with a previously cached CSRF token", function()
    local api, posts = loadApi(), 0
    api.last_csrf = "synthetic-old-token"
    api.request = function(_, _, method)
      if method == "POST" then posts = posts + 1 end
      return 200, '<form action="/users/sign_in"></form>', {}
    end
    local _, outcome = api:createJournalEntry {book_id="book-1",entry="Synthetic"}
    assert.are.equal("auth", outcome.category)
    assert.are.equal(0, posts)
  end)

end)
