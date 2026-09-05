-- Outcomes contain only safe diagnostic codes, never response bodies or notes.
local Result = {}

function Result:confirmed()
  return { status = "confirmed" }
end

function Result:failure(status, reason, category, retry_after)
  return { status = status, reason = reason, category = category, retry_after = retry_after }
end

function Result:response(code, headers, phase)
  headers = headers or {}
  local location = headers.location or ""
  if code == 401 or code == 403 or location:match("/users/sign_in") then
    return self:failure("rejected", "unauthorized", "auth")
  end
  if code == 202 then
    return self:failure("uncertain", "verification_failed", "transient")
  end
  if code and code >= 200 and code < 300 then return self:confirmed() end
  if (code == 302 or code == 303)
      and (location:match("^/books/[^/]+")
        or location:match("^https://app%.thestorygraph%.com/books/[^/]+")) then
    return self:confirmed()
  end
  if code == 429 then
    return self:failure("rejected", "rate_limited", "transient", tonumber(headers["retry-after"]))
  end
  if code and code >= 400 and code < 500 and code ~= 408 then
    return self:failure("rejected", "invalid_request", "permanent")
  end
  -- A lost response or a server failure after POST does not prove rejection.
  return self:failure(phase == "read" and "rejected" or "uncertain", "remote_error", "transient")
end

function Result:verify(operation, state)
  if type(state) ~= "table" then return false, "verification_failed" end
  if state.id and tostring(state.id) ~= tostring(operation.book_id) then
    return false, "edition_mismatch"
  end
  local payload = operation.payload
  if operation.kind == "status" then
    return state.status_id == payload.status_id, "status_unconfirmed"
  end
  if operation.kind ~= "progress" then return false, "note_uncertain" end
  if state._storygraph_skipped then return true end
  if state.status_id ~= 2 then
    return false, state.status_id and "not_reading" or "progress_unconfirmed"
  end
  local expected = tonumber(payload.value)
  local actual
  if payload.update_type == "pages" then
    actual = tonumber(state.last_reached_pages)
  else
    actual = tonumber(state.last_reached_percent or state.percent_finished)
  end
  if not expected or not actual then return false, "progress_unconfirmed" end
  return (payload.allow_regression == true and actual == expected)
    or (payload.allow_regression ~= true and actual >= expected), "progress_unconfirmed"
end

return Result
