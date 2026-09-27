-- Persisted evidence authorizes GET-only checks, never another POST.
local Verification = { max_attempts = 3 }
local reasons = {
  confirmed=true, baseline_unavailable=true, journal_unavailable=true,
  journal_unrecognized=true, journal_changed=true, entry_absent=true,
  entry_ambiguous=true, entry_unavailable=true, entry_mismatch=true,
  verification_exception=true, unauthorized=true,
}

function Verification:reason(reason)
  return reasons[reason] and reason or "verification_exception"
end

function Verification:retryable(reason)
  return reason == "entry_absent" or reason == "journal_unavailable"
    or reason == "entry_unavailable" or reason == "verification_exception"
end

function Verification:valid(context, book_id)
  if type(book_id) ~= "string" or not book_id:match("^[%w%-]+$")
      or type(context) ~= "table" or context.book_id ~= book_id
      or type(context.before) ~= "table" or type(context.date) ~= "table"
      or not tonumber(context.progress)
      or (context.progress_type ~= "pages" and context.progress_type ~= "percentage")
      or type(context.attempts) ~= "number" or context.attempts < 0
      or context.attempts % 1 ~= 0 or context.attempts > self.max_attempts then return false end
  for _, part in ipairs({"day", "month", "year"}) do
    if not tonumber(context.date[part]) then return false end
  end
  local count = 0
  for id, present in pairs(context.before) do
    if type(id) ~= "string" or not id:match("^[%w%-]+$") or present ~= true then return false end
    count = count + 1
  end
  return count <= 200
end

function Verification:pending(operation)
  return operation.kind == "note" and operation.delivery_state ~= nil
    and self:valid(operation.note_verification, operation.book_id)
    and operation.note_verification.attempts < self.max_attempts
end

-- Only known routes are logged; arbitrary paths may themselves contain secrets.
function Verification:redirect(headers)
  local location = type(headers) == "table" and headers.location
  if type(location) ~= "string" or location == "" then return "none" end
  local path = location:gsub("^https://app%.thestorygraph%.com/", "/"):match("^[^?#]+")
  if path == "/journal" or path == "/users/sign_in" then return path end
  if path and path:match("^/books/[%w%-]+$") then return "/books/:id" end
  if path and path:match("^/journal_entries/[%w%-]+/edit$") then return "/journal_entries/:id/edit" end
  return "other"
end

return Verification
