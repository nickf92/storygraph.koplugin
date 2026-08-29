describe("Cache", function()
  local Cache
  local original_modules = {}
  local find_calls
  local updated_filename
  local updated_values

  local module_names = {
    "storygraph/lib/hardcover_api",
    "storygraph/lib/user",
    "storygraph/lib/cache",
  }

  before_each(function()
    for _, module_name in ipairs(module_names) do
      original_modules[module_name] = package.loaded[module_name]
    end

    find_calls = 0
    updated_filename = nil
    updated_values = nil

    package.loaded["storygraph/lib/hardcover_api"] = {
      findUserBook = function()
        find_calls = find_calls + 1
        return { id = 7, page_count = 321, status_id = 2 }
      end,
    }
    package.loaded["storygraph/lib/user"] = {
      getId = function() return "user-id" end,
    }
    package.loaded["storygraph/lib/cache"] = nil

    Cache = require("storygraph/lib/cache")
  end)

  after_each(function()
    for _, module_name in ipairs(module_names) do
      package.loaded[module_name] = original_modules[module_name]
    end
  end)

  local function newCache()
    return Cache:new {
      state = { book_status = { id = 42 } },
      settings = {
        getLinkedBookId = function() return "edition-id" end,
        readBookSetting = function() return nil end,
        updateBookSetting = function(_, filename, values)
          updated_filename = filename
          updated_values = values
        end,
      },
    }
  end

  it("ignores a stale refresh after the document has closed", function()
    local cache = newCache()

    local result = cache:cacheUserBook(nil)

    assert.are.same({ completed = true, cancelled = true }, result)
    assert.are.equal(0, find_calls)
    assert.are.same({ id = 42 }, cache.state.book_status)
  end)

  it("uses the captured filename without reading the live UI document", function()
    local cache = newCache()

    local result = cache:cacheUserBook("/books/current.epub")

    assert.is_nil(result)
    assert.are.equal(1, find_calls)
    assert.are.same({ id = 7, page_count = 321, status_id = 2 }, cache.state.book_status)
    assert.are.equal("/books/current.epub", updated_filename)
    assert.are.same({ pages = 321 }, updated_values)
  end)
end)
