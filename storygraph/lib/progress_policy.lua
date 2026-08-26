local ProgressPolicy = {}

function ProgressPolicy:shouldSkip(local_value, remote_value, skip_behind)
  if not skip_behind then
    return false
  end
  local local_number = tonumber(local_value)
  local remote_number = tonumber(remote_value)
  return local_number ~= nil and remote_number ~= nil and local_number <= remote_number
end

return ProgressPolicy
