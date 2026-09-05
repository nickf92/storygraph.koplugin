local loadApi = require("spec/support/load_api")
local Sender = require("storygraph/lib/sync_sender")
local function fixture()
  local f = assert(io.open("spec/fixtures/reading.html"))
  local html = f:read("*a"); f:close(); return html
end

describe("StoryGraph HTML fixtures", function()
  it("parses the edition and reading position from an HTML fixture", function()
    local api = loadApi()
    api.request = function() return 200, fixture(), {} end
    local result = api:findUserBook("book-1")
    assert.are.equal("book-1", result.id)
    assert.are.equal(2, result.status_id)
    assert.are.equal(80, result.last_reached_pages)
    assert.are.equal(40, result.last_reached_percent)
    assert.are.equal(200, result.book_num_of_pages)
    assert.are.equal("Paperback", result.edition_format)
  end)

end)
