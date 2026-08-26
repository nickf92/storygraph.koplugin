local SyncSender = {}
SyncSender.__index = SyncSender

local function copyTable(value, seen)
  seen = seen or {}
  if seen[value] then
    return seen[value]
  end
  local copy = {}
  seen[value] = copy
  for key, item in pairs(value or {}) do
    if type(item) == "table" then
      copy[key] = copyTable(item, seen)
    else
      copy[key] = item
    end
  end
  return copy
end

function SyncSender:new(options)
  options = options or {}
  assert(options.api, "api is required")
  return setmetatable({ api = options.api }, self)
end

function SyncSender:send(operation)
  if type(operation) ~= "table" or type(operation.payload) ~= "table" then
    return false, nil, "invalid_operation"
  end

  local payload = operation.payload
  local result
  if operation.kind == "progress" then
    result = self.api:updatePage(
      tostring(operation.book_id) .. "_read",
      payload.value,
      payload.started_at,
      payload.update_type,
      { skip_behind = payload.allow_regression ~= true }
    )
  elseif operation.kind == "status" then
    result = self.api:updateUserBook(operation.book_id, payload.status_id)
  elseif operation.kind == "note" then
    local note = copyTable(payload)
    note.book_id = operation.book_id
    result = self.api:createJournalEntry(note)
  else
    return false, nil, "invalid_operation"
  end

  if result == nil or result == false then
    return false, nil, "remote_error"
  end
  return true, result
end

return SyncSender
