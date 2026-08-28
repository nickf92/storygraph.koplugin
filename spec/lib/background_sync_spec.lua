local BackgroundSync = require("storygraph/lib/background_sync")

describe("BackgroundSync", function()
  local function build(options)
    options = options or {}
    local state = {
      connected = options.connected == true,
      enabled = options.enabled ~= false,
      now = options.now or 1000,
      wifi_calls = 0,
      flush_requests = 0,
      drains = 0,
      statuses = {},
      wifi_started = options.wifi_started ~= false,
    }
    local wifi_callback
    local wifi_failure_callback
    local wifi = {
      withWifi = function(_, callback, failure_callback)
        state.wifi_calls = state.wifi_calls + 1
        if options.defer_wifi then
          wifi_callback = callback
          wifi_failure_callback = failure_callback
        else
          if options.connects then
            state.connected = true
          end
          callback(state.wifi_started)
        end
        return options.wifi_accepted ~= false, options.wifi_reason
      end,
    }
    local sync = BackgroundSync:new {
      wifi = wifi,
      is_connected = function()
        return state.connected
      end,
      wifi_enabled = function()
        return state.enabled
      end,
      cooldown_seconds = function()
        return 3600
      end,
      can_attempt = function()
        return options.blocked ~= true
      end,
      request_flush = function()
        state.flush_requests = state.flush_requests + 1
        return true
      end,
      drain_now = function()
        state.drains = state.drains + 1
      end,
      now = function()
        return state.now
      end,
      on_status = function(status, details)
        state.statuses[#state.statuses + 1] = { status = status, details = details }
      end,
    }
    return sync, state, function()
      wifi_callback(state.wifi_started)
    end, function(reason)
      wifi_failure_callback(reason or "connectivity_timeout")
    end
  end

  it("flushes normally without requesting wifi when already connected", function()
    local sync, state = build { connected = true }

    assert.is_true(sync:request())
    assert.are.equal(1, state.flush_requests)
    assert.are.equal(0, state.wifi_calls)
  end)

  it("uses wifi on demand and drains when a connection succeeds", function()
    local sync, state = build { connects = true }

    assert.is_true(sync:request())
    assert.are.equal(1, state.wifi_calls)
    assert.are.equal(1, state.drains)
    assert.are.equal(0, state.flush_requests)
  end)

  it("keeps the queue untouched when wifi finds no network", function()
    local sync, state = build()

    assert.is_true(sync:request())
    assert.are.equal(1, state.wifi_calls)
    assert.are.equal(0, state.drains)
    assert.are.equal(0, state.flush_requests)
  end)

  it("does not request wifi when on demand is disabled", function()
    local sync, state = build { enabled = false }

    local accepted, reason = sync:request()
    assert.is_false(accepted)
    assert.are.equal("wifi_disabled", reason)
    assert.are.equal(0, state.wifi_calls)
  end)

  it("starts the cooldown even when no network is available", function()
    local sync, state = build()

    assert.is_true(sync:request())
    state.now = state.now + 60
    local accepted, reason = sync:request()

    assert.is_false(accepted)
    assert.are.equal("cooldown", reason)
    assert.are.equal(1, state.wifi_calls)
    assert.are.equal(1000, sync.last_auto_wifi_attempt_at)

    sync:request()
    assert.are.equal(3, #state.statuses)
  end)

  it("retains its cooldown across lifecycle events outside the coordinator", function()
    local sync, state = build()

    assert.is_true(sync:request())
    -- Suspend/resume resets page-turn scheduling, but keeps this instance alive.
    state.now = state.now + 1800
    assert.is_false(sync:request())
    state.now = state.now + 1801
    assert.is_true(sync:request())
    assert.are.equal(2, state.wifi_calls)
  end)

  it("lets a real connection bypass the wifi cooldown", function()
    local sync, state = build()

    assert.is_true(sync:request())
    state.now = state.now + 60
    state.connected = true
    assert.is_true(sync:onNetworkConnected())

    assert.are.equal(1, state.wifi_calls)
    assert.are.equal(1, state.flush_requests)
  end)

  it("prevents overlapping wifi attempts", function()
    local sync, state, finish_wifi = build { defer_wifi = true }

    assert.is_true(sync:request())
    assert.is_true(sync:isWifiAttemptPending())
    local accepted, reason = sync:request()
    assert.is_true(accepted)
    assert.are.equal("already_in_progress", reason)
    assert.are.equal(1, state.wifi_calls)

    finish_wifi()
    assert.is_false(sync:isWifiAttemptPending())
    assert.are.equal(0, state.drains)
  end)

  it("avoids a duplicate flush when NetworkConnected arrives during wifi setup", function()
    local sync, state, finish_wifi = build { defer_wifi = true }

    assert.is_true(sync:request())
    state.connected = true
    local accepted, reason = sync:onNetworkConnected()

    assert.is_false(accepted)
    assert.are.equal("automatic_wifi_attempt", reason)
    assert.are.equal(0, state.flush_requests)

    finish_wifi()
    assert.are.equal(1, state.drains)
  end)

  it("recovers after an automatic wifi attempt times out", function()
    local sync, state, _, fail_wifi = build { defer_wifi = true }

    assert.is_true(sync:request())
    assert.is_true(sync:isWifiAttemptPending())

    fail_wifi()
    assert.is_false(sync:isWifiAttemptPending())
    assert.are.equal("wifi_unavailable", state.statuses[#state.statuses].status)
    assert.are.equal("connectivity_timeout", state.statuses[#state.statuses].details.reason)

    state.connected = true
    assert.is_true(sync:onNetworkConnected())
    assert.are.equal(1, state.flush_requests)
  end)

  it("does not start a cooldown when wifi cannot be started", function()
    local sync, state = build {
      wifi_accepted = false,
      wifi_reason = "airplane_mode",
      defer_wifi = true,
    }

    local accepted, reason = sync:request()
    assert.is_false(accepted)
    assert.are.equal("wifi_not_started", reason)
    assert.is_nil(sync.last_auto_wifi_attempt_at)
    assert.are.equal(1, state.wifi_calls)
    assert.are.equal("wifi_not_started", state.statuses[#state.statuses].status)
    assert.are.equal("airplane_mode", state.statuses[#state.statuses].details.reason)

    sync:request()
    assert.are.equal(1, #state.statuses)
  end)

  it("uses an existing connection without consuming the automatic wifi cooldown", function()
    local sync, state = build { connected = true }
    local callback_calls = 0

    assert.is_true(sync:withAutomaticWifi("read_cache", function(_, connected)
      assert.is_true(connected)
      callback_calls = callback_calls + 1
    end))

    assert.are.equal(1, callback_calls)
    assert.are.equal(0, state.wifi_calls)
    assert.is_nil(sync.last_auto_wifi_attempt_at)
  end)

  it("lets read cache use wifi when the shared cooldown is available", function()
    local sync, state = build { connects = true }
    local read_cache_calls = 0

    assert.is_true(sync:withAutomaticWifi("read_cache", function(wifi_started, connected)
      assert.is_true(wifi_started)
      assert.is_true(connected)
      read_cache_calls = read_cache_calls + 1
    end))

    assert.are.equal(1, read_cache_calls)
    assert.are.equal(1, state.wifi_calls)
    assert.are.equal(1000, sync.last_auto_wifi_attempt_at)
  end)

  it("shares a failed background-sync cooldown with read cache", function()
    local sync, state = build()
    local read_cache_calls = 0

    assert.is_true(sync:request())
    state.now = state.now + 300
    local accepted, reason = sync:withAutomaticWifi("read_cache", function()
      read_cache_calls = read_cache_calls + 1
    end)

    assert.is_false(accepted)
    assert.are.equal("cooldown", reason)
    assert.are.equal(0, read_cache_calls)
    assert.are.equal(1, state.wifi_calls)
  end)

  it("shares a failed read-cache cooldown with background sync", function()
    local sync, state = build()
    local read_cache_calls = 0

    assert.is_true(sync:withAutomaticWifi("read_cache", function(_, connected)
      assert.is_false(connected)
      read_cache_calls = read_cache_calls + 1
    end))
    state.now = state.now + 300
    local accepted, reason = sync:request()

    assert.is_false(accepted)
    assert.are.equal("cooldown", reason)
    assert.are.equal(1, read_cache_calls)
    assert.are.equal(1, state.wifi_calls)
    assert.are.equal(0, state.drains)
  end)

  it("lets read cache join an active background wifi attempt", function()
    local sync, state, finish_wifi = build { defer_wifi = true }
    local read_cache_calls = 0

    assert.is_true(sync:request())
    local accepted, reason = sync:withAutomaticWifi("read_cache", function(_, connected)
      assert.is_true(connected)
      read_cache_calls = read_cache_calls + 1
    end)
    assert.is_true(accepted)
    assert.are.equal("joined_in_progress", reason)

    state.connected = true
    finish_wifi()
    assert.are.equal(1, state.wifi_calls)
    assert.are.equal(1, state.drains)
    assert.are.equal(1, read_cache_calls)
  end)

  it("shares a failed background-sync cooldown with version check", function()
    local sync, state = build()

    assert.is_true(sync:request())
    state.now = state.now + 300
    local accepted, reason = sync:withAutomaticWifi("version_check", function() end)

    assert.is_false(accepted)
    assert.are.equal("cooldown", reason)
    assert.are.equal(1, state.wifi_calls)
  end)

  it("shares a failed version-check cooldown with read cache and background sync", function()
    local sync, state = build()

    assert.is_true(sync:withAutomaticWifi("version_check", function(_, connected)
      assert.is_false(connected)
    end))
    state.now = state.now + 300

    assert.is_false(sync:withAutomaticWifi("read_cache", function() end))
    assert.is_false(sync:request())
    assert.are.equal(1, state.wifi_calls)
  end)

  it("does not apply the automatic cooldown to direct manual wifi actions", function()
    local sync, state = build()
    local manual_calls = 0

    assert.is_true(sync:request())
    state.now = state.now + 300
    sync.wifi:withWifi(function()
      manual_calls = manual_calls + 1
    end)

    assert.are.equal(1, manual_calls)
    assert.are.equal(2, state.wifi_calls)
  end)
end)
