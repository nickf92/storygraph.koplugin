local SETTING = require("storygraph/lib/constants/settings")

local Device = require("device")
local logger = require("logger")

local NetworkMgr = require("ui/network/manager")
local UIManager = require("ui/uimanager")

local CONNECTIVITY_TIMEOUT_SECONDS = 46

local AutoWifi = {
  connection_pending = false
}
AutoWifi.__index = AutoWifi

function AutoWifi:new(o)
  return setmetatable(o, self)
end

function AutoWifi:withWifi(callback, failure_callback)
  if NetworkMgr:isWifiOn() then
    callback(false)
    return true, "wifi_already_on"
  end

  if not self.settings:readSetting(SETTING.ENABLE_WIFI) then
    return false, "disabled"
  end
  if NetworkMgr.pending_connection then
    return false, "connection_pending"
  end
  if not Device:hasWifiRestore() then
    return false, "restore_unavailable"
  end
  if not G_reader_settings:nilOrFalse("airplanemode") then
    return false, "airplane_mode"
  end

    --logger.warn("HARDCOVER enabling wifi")

  local original_on = NetworkMgr.wifi_was_on
  local completed = false
  local timeout_job

  local complete = function(connected)
    if completed then
      return
    end
    completed = true
    self.connection_pending = false

    if timeout_job then
      UIManager:unschedule(timeout_job)
      timeout_job = nil
    end

    -- restore original "was on" state to prevent wifi being restored automatically after suspend
    NetworkMgr.wifi_was_on = original_on
    G_reader_settings:saveSetting("wifi_was_on", original_on)

    if connected then
      callback(true)
      self:wifiDisableSilent()
    elseif failure_callback then
      failure_callback("connectivity_timeout")
    end
  end

  self.connection_pending = true
  NetworkMgr:restoreWifiAsync()
  NetworkMgr:scheduleConnectivityCheck(function()
    --logger.warn("HARDCOVER wifi enabled")
    complete(true)
  end)

  timeout_job = function()
    timeout_job = nil
    if NetworkMgr:isConnected() then
      complete(true)
      return
    end
    logger.warn("StoryGraph: automatic Wi-Fi connectivity check timed out")
    complete(false)
  end
  UIManager:scheduleIn(CONNECTIVITY_TIMEOUT_SECONDS, timeout_job)
  return true, "started"
end

function AutoWifi:wifiDisableSilent()
  NetworkMgr:turnOffWifi(function()
    -- explicitly disable wifi was on
    NetworkMgr.wifi_was_on = false
    G_reader_settings:saveSetting("wifi_was_on", false)
    logger.info("StoryGraph: temporary wifi returned to off state")
  end)
end

function AutoWifi:wifiPrompt(callback)
  if NetworkMgr:isWifiOn() then
    if callback then
      callback(false)
    end

    return
  end

  if G_reader_settings:isTrue("airplanemode") then
    return
  end

  local network_callback = callback and function() callback(true) end or nil

  if self.settings:readSetting(SETTING.ENABLE_WIFI) then
    NetworkMgr:turnOnWifiAndWaitForConnection(network_callback)
  else
    NetworkMgr:promptWifiOn(network_callback)
  end
end

function AutoWifi:wifiDisablePrompt()
  if self.settings:readSetting(SETTING.ENABLE_WIFI) and Device:hasWifiRestore() then
    self:wifiDisableSilent()
  else
    NetworkMgr:toggleWifiOff()
  end
end

return AutoWifi
