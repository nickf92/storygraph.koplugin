local ProgressSync = {}
ProgressSync.__index = ProgressSync

function ProgressSync:new()
  return setmetatable({
    active = {},
    pending = {},
  }, self)
end

function ProgressSync:put(filename, update)
  if not filename or not update then
    return
  end

  self.pending[filename] = update
end

function ProgressSync:start(filename)
  if self.active[filename] then
    return
  end

  local update = self.pending[filename]
  if not update then
    return
  end

  self.pending[filename] = nil
  self.active[filename] = update
  return update
end

function ProgressSync:finish(filename, success)
  local update = self.active[filename]
  local has_newer_update = self.pending[filename] ~= nil
  self.active[filename] = nil

  -- A newer pending value always wins over the failed update.
  if not success and update and not self.pending[filename] then
    self.pending[filename] = update
  end

  return self.pending[filename], has_newer_update
end

function ProgressSync:hasPending(filename)
  return self.pending[filename] ~= nil
end

function ProgressSync:isActive(filename)
  return self.active[filename] ~= nil
end

function ProgressSync:clear(filename)
  self.pending[filename] = nil
  self.active[filename] = nil
end

return ProgressSync
