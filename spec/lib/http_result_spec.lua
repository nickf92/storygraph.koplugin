local HttpResult = require("storygraph/lib/http_result")

describe("HttpResult", function()
  it("accepts successful mutation responses", function()
    assert.is_true(HttpResult:mutationSucceeded(200))
    assert.is_true(HttpResult:mutationSucceeded(204))
    assert.is_true(HttpResult:mutationSucceeded(302, { location = "/books/book-1" }))
  end)

  it("rejects login redirects as unauthorized", function()
    local success, reason = HttpResult:mutationSucceeded(302, {
      location = "https://app.thestorygraph.com/users/sign_in",
    })
    assert.is_false(success)
    assert.are.equal("unauthorized", reason)
  end)

  it("classifies authorization and transient failures", function()
    local success, reason = HttpResult:mutationSucceeded(403)
    assert.is_false(success)
    assert.are.equal("unauthorized", reason)

    success, reason = HttpResult:mutationSucceeded(503)
    assert.is_false(success)
    assert.are.equal("remote_error", reason)
  end)
end)
