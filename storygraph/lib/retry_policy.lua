local Retry = {}

function Retry:plan(operation, outcome, now, random, base, maximum)
  local attempts = (tonumber(operation.attempt_count) or 0) + 1
  local reason = outcome.reason or "send_failed"
  local category = outcome.category or "transient"
  if operation.kind == "note" and outcome.status == "uncertain" and category ~= "auth" then
    category, reason = "reconciliation", "note_uncertain"
  elseif reason == "not_reading" then
    category = "permanent"
  end
  local next_attempt
  if category == "transient" then
    local delay = math.min(maximum, base * 2 ^ math.min(attempts - 1, 16))
    delay = math.min(maximum, math.ceil(delay * (0.8 + random() * 0.4)))
    delay = math.max(delay, tonumber(outcome.retry_after) or 0, 1)
    next_attempt = now + delay
  end
  return {
    attempt_count = attempts,
    last_error = reason,
    next_attempt_at = next_attempt,
    blocked_reason = category ~= "transient" and category or nil,
  }
end

return Retry
