describe("AutoWifi", function()
  local AutoWifi
  local original_modules = {}
  local original_reader_settings
  local connectivity_callback
  local timeout_job
  local unscheduled_job
  local turn_off_calls

  local module_names = {
    "device",
    "logger",
    "ui/network/manager",
    "ui/uimanager",
    "storygraph/lib/auto_wifi",
  }

  before_each(function()
    for _, module_name in ipairs(module_names) do
      original_modules[module_name] = package.loaded[module_name]
    end
    original_reader_settings = G_reader_settings

    package.loaded["device"] = {
      hasWifiRestore = function() return true end,
    }
    package.loaded["logger"] = {
      info = function() end,
      warn = function() end,
    }
    package.loaded["ui/network/manager"] = {
      pending_connection = false,
      wifi_was_on = false,
      isWifiOn = function() return false end,
      isConnected = function() return false end,
      restoreWifiAsync = function() end,
      scheduleConnectivityCheck = function(_, callback)
        connectivity_callback = callback
      end,
      turnOffWifi = function(_, callback)
        turn_off_calls = turn_off_calls + 1
        callback()
      end,
    }
    package.loaded["ui/uimanager"] = {
      scheduleIn = function(_, _, job)
        timeout_job = job
      end,
      unschedule = function(_, job)
        unscheduled_job = job
      end,
    }
    package.loaded["storygraph/lib/auto_wifi"] = nil

    G_reader_settings = {
      nilOrFalse = function() return true end,
      saveSetting = function() end,
    }
    turn_off_calls = 0
    AutoWifi = require("storygraph/lib/auto_wifi")
  end)

  after_each(function()
    for _, module_name in ipairs(module_names) do
      package.loaded[module_name] = original_modules[module_name]
    end
    G_reader_settings = original_reader_settings
    connectivity_callback = nil
    timeout_job = nil
    unscheduled_job = nil
  end)

  local function newWifi()
    return AutoWifi:new {
      settings = {
        readSetting = function() return true end,
      },
    }
  end

  it("reports a connectivity timeout exactly once", function()
    local successes = 0
    local failures = 0
    local failure_reason
    local wifi = newWifi()

    assert.is_true(wifi:withWifi(function()
      successes = successes + 1
    end, function(reason)
      failures = failures + 1
      failure_reason = reason
    end))

    assert.is_function(timeout_job)
    timeout_job()
    assert.are.equal(0, successes)
    assert.are.equal(1, failures)
    assert.are.equal("connectivity_timeout", failure_reason)

    connectivity_callback()
    assert.are.equal(0, successes)
    assert.are.equal(1, failures)
  end)

  it("cancels the timeout after a successful connection", function()
    local successes = 0
    local failures = 0
    local wifi = newWifi()

    assert.is_true(wifi:withWifi(function()
      successes = successes + 1
    end, function()
      failures = failures + 1
    end))

    connectivity_callback()
    assert.are.equal(1, successes)
    assert.are.equal(0, failures)
    assert.are.equal(timeout_job, unscheduled_job)
    assert.are.equal(1, turn_off_calls)

    timeout_job()
    assert.are.equal(1, successes)
    assert.are.equal(0, failures)
  end)
end)
