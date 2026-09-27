local Queue = require("storygraph/lib/sync_queue")
local function loadMenu()
  local env = setmetatable({require=function(name)
    if name == "gettext" then return function(text) return text end end
    return require(name)
  end}, {__index=_G})
  return setfenv(assert(loadfile("storygraph/lib/ui/sync_queue_menu.lua")),env)()
end

describe("Uncertain-note recovery menu", function()
  it("distinguishes scheduled verification from exhausted manual recovery", function()
    local now=1000
    local queue=Queue:new {now=function() return now end}
    queue:enqueue {document="book.epub",book_id="book",kind="note",payload={entry="Synthetic"}}
    local op=queue:start()
    assert.is_true(queue:prepareNoteVerification(op.id, {book_id="book",before={},attempts=0,
      date={year=2026,month=9,day=27},progress=40,progress_type="percentage"}))
    local outcome={status="uncertain",category="reconciliation",verification_reason="entry_absent"}
    queue:finish(op.id,false,outcome)
    local items=loadMenu():items(queue,{})
    assert.matches("Waiting to verify delivery", items[1].text, 1, true)
    for _, choice in ipairs(items[1].sub_item_table) do assert.not_equals("Retry now", choice.text) end
    for attempt=1,3 do
      now=queue:nextAttemptAt(); op=queue:start()
      -- At the last check, simulate a crash before recording the outcome.
      if attempt < 3 then queue:finish(op.id,false,outcome) end
    end
    items=loadMenu():items(queue,{})
    assert.matches("Check delivery",items[1].text,1,true)
    assert.is_nil(queue:nextAttemptAt())
  end)

  it("does not resend until the user explicitly confirms the duplicate risk", function()
    local queue=Queue:new()
    local op=queue:enqueue {document="book.epub",book_id="book",kind="note",payload={entry="Synthetic"}}
    queue:finish(queue:start().id,false,{status="uncertain",category="transient"})
    local confirmation, resolution
    local items=loadMenu():items(queue,{
      show=function() end,
      confirm=function(options) confirmation=options end,
      retry=function(id, delivered) resolution={id=id,delivered=delivered} end,
    })
    items[1].sub_item_table[3].callback()
    assert.is_nil(resolution)
    assert.matches("duplicate",confirmation.text)
    confirmation.ok_callback()
    assert.are.equal(op.id,resolution.id)
    assert.is_false(resolution.delivered)
  end)
end)
