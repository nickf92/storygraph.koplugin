local ProgressPolicy = require("storygraph/lib/progress_policy")

describe("ProgressPolicy", function()
  it("skips stale and duplicate automatic progress", function()
    assert.is_true(ProgressPolicy:shouldSkip(40, 50, true))
    assert.is_true(ProgressPolicy:shouldSkip("50", "50", true))
  end)

  it("allows progress which advances the remote value", function()
    assert.is_false(ProgressPolicy:shouldSkip(51, 50, true))
  end)

  it("allows explicit regressions", function()
    assert.is_false(ProgressPolicy:shouldSkip(40, 50, false))
  end)

  it("does not discard an update when comparison data is unavailable", function()
    assert.is_false(ProgressPolicy:shouldSkip(40, nil, true))
    assert.is_false(ProgressPolicy:shouldSkip(nil, 40, true))
  end)
end)
