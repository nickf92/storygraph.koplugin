local Api = require("storygraph/lib/hardcover_api")
local User = require("storygraph/lib/user")

local Cache = {}
Cache.__index = Cache

function Cache:new(o)
  return setmetatable(o, self)
end

function Cache:updateBookStatus(filename, status)
  local settings = self.settings:readBookSettings(filename)
  local book_id = settings.book_id
  if self.enqueue_operation then
    local queued, err = self.enqueue_operation({
      document = filename,
      book_id = book_id,
      kind = "status",
      payload = { status_id = status },
    })
    if queued and self.ui.document and self.ui.document.file == filename then
      self.state.book_status.status_id = status
    end
    return queued, err
  end

  local updated_status = Api:updateUserBook(book_id, status)
  if updated_status then
    self.state.book_status = updated_status
  end
  return updated_status
end

function Cache:cacheUserBook()
  local filename = self.ui.document.file
  local status, errors = Api:findUserBook(self.settings:getLinkedBookId(), User:getId())
  self.state.book_status = status or {}

  if status and status.page_count and status.page_count > 0 then
    local current_pages = self.settings:readBookSetting(filename, "pages")
    if not current_pages or current_pages == 0 then
      self.settings:updateBookSetting(filename, { pages = status.page_count })
    end
  end

  return errors
end

return Cache
