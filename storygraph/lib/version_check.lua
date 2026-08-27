local SECONDS_PER_DAY = 24 * 60 * 60

local VersionCheck = {}
VersionCheck.__index = VersionCheck

function VersionCheck:new(options)
  options = options or {}
  assert(options.automatic_wifi, "automatic_wifi is required")
  assert(options.manual_wifi, "manual_wifi is required")
  assert(type(options.is_connected) == "function", "is_connected is required")
  assert(type(options.fetch) == "function", "fetch is required")
  assert(type(options.read_last_check) == "function", "read_last_check is required")
  assert(type(options.read_interval_days) == "function", "read_interval_days is required")
  assert(type(options.write_last_check) == "function", "write_last_check is required")
  assert(type(options.schedule_in) == "function", "schedule_in is required")
  assert(type(options.unschedule) == "function", "unschedule is required")

  return setmetatable({
    automatic_wifi = options.automatic_wifi,
    manual_wifi = options.manual_wifi,
    is_connected = options.is_connected,
    fetch = options.fetch,
    read_last_check = options.read_last_check,
    read_interval_days = options.read_interval_days,
    write_last_check = options.write_last_check,
    schedule_in = options.schedule_in,
    unschedule = options.unschedule,
    can_check = options.can_check,
    on_success = options.on_success,
    on_status = options.on_status,
    now = options.now or os.time,
    scheduled_job = nil,
  }, self)
end

function VersionCheck:_report(status, details)
  if self.on_status then
    self.on_status(status, details or {})
  end
end

function VersionCheck:intervalSeconds()
  local days = tonumber(self.read_interval_days()) or 1
  return math.max(days, 1) * SECONDS_PER_DAY
end

function VersionCheck:isDue(now)
  now = now or self.now()
  local last_check = tonumber(self.read_last_check())
  return not last_check or last_check <= 0 or now - last_check >= self:intervalSeconds()
end

function VersionCheck:secondsUntilDue(now)
  now = now or self.now()
  local last_check = tonumber(self.read_last_check())
  if not last_check or last_check <= 0 then return 0 end
  return math.max(0, self:intervalSeconds() - (now - last_check))
end

function VersionCheck:schedule(delay, replace)
  if self.scheduled_job then
    if not replace then return false, "already_scheduled" end
    self.unschedule(self.scheduled_job)
    self.scheduled_job = nil
  end

  local job
  job = function()
    if self.scheduled_job ~= job then return end
    self.scheduled_job = nil
    self:initiate()
  end
  self.scheduled_job = job
  self.schedule_in(math.max(tonumber(delay) or 1, 1), job)
  return true
end

function VersionCheck:initiate()
  if self.can_check and not self.can_check() then
    return false, "disabled"
  end

  local now = self.now()
  if not self:isDue(now) then
    local remaining = self:secondsUntilDue(now)
    self:_report("not_due", { remaining_seconds = remaining })
    self:schedule(remaining)
    return false, "not_due"
  end

  self:_report("due")
  return self:check(false)
end

function VersionCheck:_perform(connected)
  if not connected then
    self:_report("offline")
    return false, "offline"
  end

  local fetched, info = pcall(self.fetch)
  if not fetched or not info then
    self:_report("fetch_failed")
    return false, "fetch_failed"
  end

  self.write_last_check(self.now())
  self:_report("succeeded")
  local schedule_next = not self.on_success or self.on_success(info) ~= false
  if schedule_next then
    self:schedule(self:intervalSeconds(), true)
  elseif self.scheduled_job then
    self.unschedule(self.scheduled_job)
    self.scheduled_job = nil
  end
  return true, info
end

function VersionCheck:check(manual)
  if self.can_check and not self.can_check() then
    return false, "disabled"
  end

  local callback = function(_, connected)
    self:_perform(connected)
  end

  local accepted, reason
  if manual then
    accepted, reason = self.manual_wifi:withWifi(function(wifi_started)
      callback(wifi_started, self.is_connected())
    end)
  else
    accepted, reason = self.automatic_wifi:withAutomaticWifi("version_check", callback)
  end

  if not accepted then
    self:_report("skipped", { reason = reason })
  end
  return accepted, reason
end

return VersionCheck
