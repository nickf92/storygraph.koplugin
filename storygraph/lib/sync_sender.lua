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

local MutationResult = require("storygraph/lib/mutation_result")

function SyncSender:new(options)
  options = options or {}
  assert(options.api, "api is required")
  return setmetatable({ api = options.api }, self)
end

function SyncSender:send(operation)
  if type(operation) ~= "table" or type(operation.payload) ~= "table" then
    return false, nil, "invalid_operation"
  end

  if operation.delivery_state then
    if operation.kind == "note" then
      local outcome = MutationResult:failure("uncertain", "note_uncertain", "reconciliation")
      return false, nil, outcome.reason, outcome
    end
    -- After a lost response or restart, observe the remote state before another
    -- mutation. A failed refresh must never repeat an acknowledged POST blindly.
    local ok, state, _, read_outcome = pcall(self.api.findUserBook, self.api, operation.book_id, nil, true)
    if read_outcome and read_outcome.category == "auth" then
      read_outcome.status = "uncertain"
      return false, nil, read_outcome.reason, read_outcome
    end
    local confirmed, reason = MutationResult:verify(operation, ok and state or nil)
    if confirmed then return true, state, nil, MutationResult:confirmed() end
    local observed = ok and type(state) == "table" and state.id and state.status_id
    local outcome = MutationResult:failure(observed and "rejected" or "uncertain",
      reason, reason == "not_reading" and "permanent" or "transient")
    return false, nil, reason, outcome
  end

  local payload = operation.payload
  local result, outcome
  if operation.kind == "progress" then
    result, outcome = self.api:updatePage(
      tostring(operation.book_id) .. "_read",
      payload.value,
      payload.started_at,
      payload.update_type,
      { skip_behind = payload.allow_regression ~= true }
    )
  elseif operation.kind == "status" then
    result, outcome = self.api:updateUserBook(operation.book_id, payload.status_id)
  elseif operation.kind == "note" then
    local note = copyTable(payload)
    note.book_id = operation.book_id
    result, outcome = self.api:createJournalEntry(note)
  else
    return false, nil, "invalid_operation"
  end

  if outcome then
    return outcome.status == "confirmed", result, outcome.reason, outcome
  end
  -- Legacy callers/test adapters must still provide observable confirmation.
  local confirmed, reason = MutationResult:verify(operation, result)
  if confirmed then return true, result, nil, MutationResult:confirmed() end
  reason = result == nil and "remote_error" or reason
  return false, result, reason, MutationResult:failure("uncertain", reason, "transient")
end

return SyncSender
