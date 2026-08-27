local BackgroundSync = {}
BackgroundSync.__index = BackgroundSync

function BackgroundSync:new(options)
  options = options or {}
  assert(options.wifi, "wifi is required")
  assert(type(options.is_connected) == "function", "is_connected is required")
  assert(type(options.wifi_enabled) == "function", "wifi_enabled is required")
  assert(type(options.cooldown_seconds) == "function", "cooldown_seconds is required")
  assert(type(options.request_flush) == "function", "request_flush is required")
  assert(type(options.drain_now) == "function", "drain_now is required")

  return setmetatable({
    wifi = options.wifi,
    is_connected = options.is_connected,
    wifi_enabled = options.wifi_enabled,
    cooldown_seconds = options.cooldown_seconds,
    request_flush = options.request_flush,
    drain_now = options.drain_now,
    can_attempt = options.can_attempt,
    now = options.now or os.time,
    on_status = options.on_status,
    last_auto_wifi_attempt_at = nil,
    last_reported_skip = nil,
    wifi_attempt_pending = false,
  }, self)
end

function BackgroundSync:_report(status, details)
  if self.on_status then
    self.on_status(status, details or {})
  end
end

function BackgroundSync:_reportSkip(status, details)
  local key = status .. ":" .. tostring(details and details.reason or "")
  if self.last_reported_skip == key then
    return
  end
  self.last_reported_skip = key
  self:_report(status, details)
end

function BackgroundSync:isWifiAttemptPending()
  return self.wifi_attempt_pending
end

function BackgroundSync:onNetworkConnected()
  if self.wifi_attempt_pending then
    self:_report("connected_during_wifi_attempt")
    return false, "background_wifi_attempt"
  end
  self.last_reported_skip = nil
  return self.request_flush(), "connected"
end

function BackgroundSync:request()
  if self.wifi_attempt_pending then
    self:_reportSkip("already_in_progress")
    return false, "already_in_progress"
  end

  if self.is_connected() then
    self.last_reported_skip = nil
    return self.request_flush(), "connected"
  end

  if self.can_attempt then
    local can_attempt, block_reason = self.can_attempt()
    if not can_attempt then
      self:_reportSkip("blocked", { reason = block_reason or "unknown" })
      return false, "blocked"
    end
  end

  if not self.wifi_enabled() then
    self:_reportSkip("wifi_disabled")
    return false, "wifi_disabled"
  end

  local now = self.now()
  local cooldown = math.max(tonumber(self.cooldown_seconds()) or 0, 0)
  if self.last_auto_wifi_attempt_at
      and now - self.last_auto_wifi_attempt_at < cooldown then
    self:_reportSkip("cooldown", {
      cooldown_seconds = cooldown,
      remaining_seconds = cooldown - (now - self.last_auto_wifi_attempt_at),
    })
    return false, "cooldown"
  end

  local previous_attempt_at = self.last_auto_wifi_attempt_at
  self.last_auto_wifi_attempt_at = now
  self.wifi_attempt_pending = true

  local attempt_reported = false
  local reportAttempt = function()
    if attempt_reported then return end
    attempt_reported = true
    self.last_reported_skip = nil
    self:_report("trying_wifi", { cooldown_seconds = cooldown })
  end

  local accepted, not_started_reason = self.wifi:withWifi(function()
    reportAttempt()
    if self.is_connected() then
      self:_report("wifi_connected")
      self.drain_now()
    else
      self:_report("wifi_unavailable", { cooldown_seconds = cooldown })
    end
    self.wifi_attempt_pending = false
  end)

  if not accepted then
    self.last_auto_wifi_attempt_at = previous_attempt_at
    self.wifi_attempt_pending = false
    self:_reportSkip("wifi_not_started", { reason = not_started_reason or "unavailable" })
    return false, "wifi_not_started"
  end

  reportAttempt()
  return true, "wifi_attempt"
end

return BackgroundSync
