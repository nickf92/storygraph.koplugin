local Queue = require("storygraph/lib/sync_queue")
local function loadMenu()
  local env = setmetatable({require=function(name)
    if name == "gettext" then return function(text) return text end end
    return require(name)
  end}, {__index=_G})
  return setfenv(assert(loadfile("storygraph/lib/ui/sync_queue_menu.lua")),env)()
end

describe("Uncertain-note recovery menu", function()
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
