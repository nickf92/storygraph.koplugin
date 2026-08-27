local VersionCheck = require("storygraph/lib/version_check")

describe("VersionCheck", function()
  local DAY = 24 * 60 * 60

  local function build(options)
    options = options or {}
    local state = {
      now = options.now or 10 * DAY,
      last_check = options.last_check,
      interval_days = options.interval_days or 7,
      connected = options.connected == true,
      cooldown_active = options.cooldown_active == true,
      automatic_gate_calls = 0,
      automatic_radio_calls = 0,
      manual_wifi_calls = 0,
      fetch_calls = 0,
      writes = {},
      schedules = {},
      unschedules = 0,
      statuses = {},
      success_calls = 0,
    }

    local automatic_wifi = {
      withAutomaticWifi = function(_, consumer, callback)
        assert.are.equal("version_check", consumer)
        state.automatic_gate_calls = state.automatic_gate_calls + 1
        if state.connected then
          callback(false, true)
          return true, "connected"
        end
        if state.cooldown_active then
          return false, "cooldown"
        end

        state.automatic_radio_calls = state.automatic_radio_calls + 1
        state.cooldown_active = true
        if options.automatic_connects then
          state.connected = true
        end
        callback(true, state.connected)
        return true, "wifi_attempt"
      end,
    }
    local manual_wifi = {
      withWifi = function(_, callback)
        state.manual_wifi_calls = state.manual_wifi_calls + 1
        if options.manual_connects ~= false then
          state.connected = true
        end
        callback(true)
        return true, "started"
      end,
    }

    local checker = VersionCheck:new {
      automatic_wifi = automatic_wifi,
      manual_wifi = manual_wifi,
      is_connected = function()
        return state.connected
      end,
      fetch = function()
        state.fetch_calls = state.fetch_calls + 1
        if options.fetch_throws then error("invalid version payload") end
        if options.fetch_fails then return nil end
        return options.fetch_result or { plugin_version = "1.2.3" }
      end,
      read_last_check = function()
        return state.last_check
      end,
      read_interval_days = function()
        return state.interval_days
      end,
      write_last_check = function(timestamp)
        state.last_check = timestamp
        state.writes[#state.writes + 1] = timestamp
      end,
      schedule_in = function(delay, job)
        state.schedules[#state.schedules + 1] = { delay = delay, job = job }
      end,
      unschedule = function()
        state.unschedules = state.unschedules + 1
      end,
      can_check = function()
        return options.disabled ~= true
      end,
      on_success = function(info)
        state.success_calls = state.success_calls + 1
        state.last_info = info
        return options.schedule_after_success ~= false
      end,
      on_status = function(status, details)
        state.statuses[#state.statuses + 1] = { status = status, details = details }
      end,
      now = function()
        return state.now
      end,
    }
    return checker, state
  end

  it("does not force a recent check in a new session", function()
    local checker, state = build { last_check = 9 * DAY }

    local accepted, reason = checker:initiate()

    assert.is_false(accepted)
    assert.are.equal("not_due", reason)
    assert.are.equal(0, state.automatic_gate_calls)
    assert.are.equal(1, #state.schedules)
    assert.are.equal(6 * DAY, state.schedules[1].delay)
  end)

  it("checks immediately without radio activation when already connected", function()
    local checker, state = build { connected = true, last_check = 1 }

    assert.is_true(checker:initiate())

    assert.are.equal(1, state.automatic_gate_calls)
    assert.are.equal(0, state.automatic_radio_calls)
    assert.are.equal(1, state.fetch_calls)
    assert.are.equal(state.now, state.last_check)
  end)

  it("uses automatic wifi for an offline check when cooldown is available", function()
    local checker, state = build { automatic_connects = true }

    assert.is_true(checker:initiate())

    assert.are.equal(1, state.automatic_radio_calls)
    assert.are.equal(1, state.fetch_calls)
    assert.are.equal(state.now, state.last_check)
  end)

  it("keeps a due check unchanged when shared cooldown is active", function()
    local checker, state = build { cooldown_active = true }

    local accepted, reason = checker:initiate()

    assert.is_false(accepted)
    assert.are.equal("cooldown", reason)
    assert.are.equal(0, state.automatic_radio_calls)
    assert.are.equal(0, state.fetch_calls)
    assert.are.equal(0, #state.writes)
  end)

  it("does not mark an offline wifi attempt as a successful check", function()
    local checker, state = build()

    assert.is_true(checker:initiate())

    assert.are.equal(1, state.automatic_radio_calls)
    assert.are.equal(0, state.fetch_calls)
    assert.are.equal(0, #state.writes)
    assert.are.equal(0, #state.schedules)
  end)

  it("does not reactivate wifi for additional books during cooldown", function()
    local checker, state = build()

    checker:initiate()
    checker:initiate()
    checker:initiate()

    assert.are.equal(1, state.automatic_radio_calls)
    assert.are.equal(0, #state.writes)
  end)

  it("allows a manual check to bypass automatic cooldown", function()
    local checker, state = build { cooldown_active = true }

    assert.is_true(checker:check(true))

    assert.are.equal(0, state.automatic_radio_calls)
    assert.are.equal(1, state.manual_wifi_calls)
    assert.are.equal(1, state.fetch_calls)
    assert.are.equal(state.now, state.last_check)
  end)

  it("keeps the last success unchanged when fetch fails online", function()
    local checker, state = build {
      connected = true,
      fetch_fails = true,
      last_check = 1,
    }

    assert.is_true(checker:initiate())

    assert.are.equal(1, state.fetch_calls)
    assert.are.equal(0, state.automatic_radio_calls)
    assert.are.equal(1, state.last_check)
    assert.are.equal(0, #state.schedules)
  end)

  it("keeps the last success unchanged when version parsing raises an error", function()
    local checker, state = build {
      connected = true,
      fetch_throws = true,
      last_check = 1,
    }

    assert.is_true(checker:initiate())

    assert.are.equal(1, state.fetch_calls)
    assert.are.equal(1, state.last_check)
    assert.are.equal(0, #state.writes)
  end)

  it("keeps only one scheduled job and replaces it after success", function()
    local checker, state = build { connected = true }

    assert.is_true(checker:schedule(10))
    assert.is_false(checker:schedule(20))
    assert.are.equal(1, #state.schedules)

    assert.is_true(checker:check(false))
    assert.are.equal(1, state.unschedules)
    assert.are.equal(2, #state.schedules)
    assert.are.equal(7 * DAY, state.schedules[2].delay)
  end)

  it("does not schedule another check when result handling blocks updates", function()
    local checker, state = build {
      connected = true,
      schedule_after_success = false,
    }

    checker:schedule(10)
    assert.is_true(checker:check(false))

    assert.are.equal(1, #state.writes)
    assert.are.equal(1, state.success_calls)
    assert.are.equal(1, #state.schedules)
    assert.are.equal(1, state.unschedules)
    assert.is_nil(checker.scheduled_job)
  end)
end)
