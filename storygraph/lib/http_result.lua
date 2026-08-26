local HttpResult = {}

function HttpResult:mutationSucceeded(code, headers)
  if code and code >= 200 and code < 300 then
    return true
  end
  if code == 302 then
    local location = headers and headers["location"] or ""
    if location:match("/users/sign_in") then
      return false, "unauthorized"
    end
    return true
  end
  if code == 401 or code == 403 then
    return false, "unauthorized"
  end
  return false, "remote_error"
end

return HttpResult
