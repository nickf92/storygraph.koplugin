local HARDCOVER = require("storygraph/lib/constants/hardcover")

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

local function progressConfirmed(payload, result)
  if type(result) ~= "table" then
    return false, "remote_error"
  end
  if result._storygraph_skipped then
    return true
  end
  if result.status_id ~= HARDCOVER.STATUS.READING then
    if result.status_id ~= nil then
      return false, "not_reading"
    end
    return false, "progress_unconfirmed"
  end

  local expected = tonumber(payload.value)
  local update_type = payload.update_type or "percentage"
  local actual = update_type == "pages"
    and tonumber(result.last_reached_pages)
    or tonumber(result.last_reached_percent or result.percent_finished)
  if expected == nil or actual == nil then
    return false, "progress_unconfirmed"
  end

  local confirmed
  if payload.allow_regression == true then
    confirmed = actual == expected
  else
    confirmed = actual >= expected
  end
  if not confirmed then
    return false, "progress_unconfirmed"
  end
  return true
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
    local confirmed, reason = progressConfirmed(payload, result)
    if not confirmed then
      return false, result, reason
    end
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
