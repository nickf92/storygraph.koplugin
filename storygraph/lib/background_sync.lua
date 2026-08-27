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
    reported_skips = {},
    wifi_attempt_pending = false,
    wifi_attempt_consumer = nil,
    wifi_attempt_waiters = {},
  }, self)
end

function BackgroundSync:_report(status, details)
  if self.on_status then
    self.on_status(status, details or {})
  end
end

function BackgroundSync:_reportSkip(status, details)
  local key = table.concat({
    status,
    tostring(details and details.consumer or ""),
    tostring(details and details.reason or ""),
  }, ":")
  if self.reported_skips[key] then
    return
  end
  self.reported_skips[key] = true
  self:_report(status, details)
end

function BackgroundSync:isWifiAttemptPending()
  return self.wifi_attempt_pending
end

function BackgroundSync:onNetworkConnected()
  if self.wifi_attempt_pending then
    self:_report("connected_during_wifi_attempt")
    return false, "automatic_wifi_attempt"
  end
  self.reported_skips = {}
  return self.request_flush(), "connected"
end

function BackgroundSync:withAutomaticWifi(consumer, callback)
  consumer = consumer or "automatic"
  assert(type(callback) == "function", "callback is required")

  if self.wifi_attempt_pending then
    if self.wifi_attempt_consumer == consumer then
      self:_reportSkip("already_in_progress", { consumer = consumer })
      return true, "already_in_progress"
    end
    for _, waiter in ipairs(self.wifi_attempt_waiters) do
      if waiter.consumer == consumer then
        return true, "already_joined"
      end
    end
    self.wifi_attempt_waiters[#self.wifi_attempt_waiters + 1] = {
      consumer = consumer,
      callback = callback,
    }
    self:_reportSkip("joined_in_progress", { consumer = consumer })
    return true, "joined_in_progress"
  end

  if self.is_connected() then
    self.reported_skips = {}
    callback(false, true)
    return true, "connected"
  end

  if not self.wifi_enabled() then
    self:_reportSkip("wifi_disabled", { consumer = consumer })
    return false, "wifi_disabled"
  end

  local now = self.now()
  local cooldown = math.max(tonumber(self.cooldown_seconds()) or 0, 0)
  if self.last_auto_wifi_attempt_at
      and now - self.last_auto_wifi_attempt_at < cooldown then
    self:_reportSkip("cooldown", {
      consumer = consumer,
      cooldown_seconds = cooldown,
      remaining_seconds = cooldown - (now - self.last_auto_wifi_attempt_at),
    })
    return false, "cooldown"
  end

  local previous_attempt_at = self.last_auto_wifi_attempt_at
  self.last_auto_wifi_attempt_at = now
  self.wifi_attempt_pending = true
  self.wifi_attempt_consumer = consumer

  local attempt_reported = false
  local reportAttempt = function()
    if attempt_reported then return end
    attempt_reported = true
    self.reported_skips = {}
    self:_report("trying_wifi", { consumer = consumer, cooldown_seconds = cooldown })
  end

  local accepted, not_started_reason = self.wifi:withWifi(function(wifi_started)
    reportAttempt()
    local connected = self.is_connected()
    local waiters = self.wifi_attempt_waiters
    self.wifi_attempt_waiters = {}
    self.wifi_attempt_pending = false
    self.wifi_attempt_consumer = nil

    local notify = function(target_consumer, target_callback)
      if connected then
        self:_report("wifi_connected", { consumer = target_consumer })
      else
        self:_report("wifi_unavailable", {
          consumer = target_consumer,
          cooldown_seconds = cooldown,
        })
      end
      target_callback(wifi_started == true, connected)
    end

    notify(consumer, callback)
    for _, waiter in ipairs(waiters) do
      notify(waiter.consumer, waiter.callback)
    end
  end)

  if not accepted then
    self.last_auto_wifi_attempt_at = previous_attempt_at
    self.wifi_attempt_pending = false
    self.wifi_attempt_consumer = nil
    self.wifi_attempt_waiters = {}
    self:_reportSkip("wifi_not_started", {
      consumer = consumer,
      reason = not_started_reason or "unavailable",
    })
    return false, "wifi_not_started"
  end

  reportAttempt()
  return true, "wifi_attempt"
end

function BackgroundSync:request()
  if not self.is_connected() and self.can_attempt then
    local can_attempt, block_reason = self.can_attempt()
    if not can_attempt then
      self:_reportSkip("blocked", {
        consumer = "background_sync",
        reason = block_reason or "unknown",
      })
      return false, "blocked"
    end
  end

  return self:withAutomaticWifi("background_sync", function(wifi_started, connected)
    if connected then
      if wifi_started then
        self.drain_now()
      else
        self.request_flush()
      end
    end
  end)
end

return BackgroundSync
