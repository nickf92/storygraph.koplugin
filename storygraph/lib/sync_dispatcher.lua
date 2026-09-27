local SyncDispatcher = {}
SyncDispatcher.__index = SyncDispatcher

function SyncDispatcher:new(options)
  options = options or {}
  assert(options.queue, "queue is required")
  assert(type(options.is_connected) == "function", "is_connected is required")
  assert(type(options.send) == "function", "send is required")

  return setmetatable({
    queue = options.queue,
    is_connected = options.is_connected,
    send = options.send,
    on_success = options.on_success,
    on_failure = options.on_failure,
    busy = false,
  }, self)
end

function SyncDispatcher:drainOne()
  if self.busy then
    return false, "busy"
  end
  if not self.is_connected() then
    return false, "offline"
  end

  local operation, start_error = self.queue:start()
  if not operation then
    if start_error then return false, start_error end
    return true, "empty"
  end

  self.busy = true
  local called, success, result, reason, outcome = pcall(self.send, operation, function(context)
    return self.queue:prepareNoteVerification(operation.id, context)
  end)
  if not called then
    reason = "send_exception"
    success = false
    result = nil
  else
    success = success == true
  end

  if not success then
    outcome = outcome or {status = "uncertain", category = "transient", reason = reason or "send_failed"}
    if operation.kind == "note" and outcome.status == "uncertain" and outcome.category ~= "auth" then
      outcome.category, outcome.reason = "reconciliation", "note_uncertain"
      reason = outcome.reason
    end
  end
  local completed, finish_error = self.queue:finish(operation.id, success, outcome)
  self.busy = false

  if not success and completed and finish_error == "superseded" then
    if self.on_failure then
      pcall(self.on_failure, operation, finish_error)
    end
    return true, "superseded", operation
  end

  if success and completed then
    if self.on_success then
      pcall(self.on_success, operation, result)
    end
    return true, "sent", operation, result
  end

  reason = finish_error or reason or "send_failed"
  if self.on_failure then
    pcall(self.on_failure, operation, reason)
  end
  return false, reason, operation
end

return SyncDispatcher
