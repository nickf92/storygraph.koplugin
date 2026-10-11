local loadUI = require("spec/support/load_ui")

-- Match native Menu's navigation contract; drawing is a device smoke test.
local NativeMenu = {}
function NativeMenu:extend(class) return setmetatable(class, {__index = self}) end
function NativeMenu:new(options)
  local menu = setmetatable(options, {__index = self})
  menu:init()
  return menu
end
function NativeMenu:init()
  self.item_table_stack = {}
  self:updateItems()
end
function NativeMenu:updateItems() self.render_count = (self.render_count or 0) + 1 end
function NativeMenu:switchItemTable(title, items)
  self.item_table = items
  self:updateItems()
end
function NativeMenu:onClose()
  if #self.item_table_stack == 0 then return self:onCloseAllMenus() end
  local parent = table.remove(self.item_table_stack)
  self:switchItemTable(parent.title, parent)
end
function NativeMenu:onCloseAllMenus()
  if self.close_callback then self.close_callback() end
end
local ActionMenu = loadUI("storygraph/lib/ui/action_menu.lua", {
  ["ui/widget/menu"] = NativeMenu,
})

describe("StoryGraph action menu navigation", function()
  it("keeps checkbox changes open and refreshes their displayed state", function()
    local enabled, callback_menu, closes = false, nil, 0
    local menu = ActionMenu:new {title="Settings", close_callback=function() closes=closes+1 end,
      item_table={{text="Tracking",checked_func=function() return enabled end,
        callback=function(m) callback_menu=m; enabled=not enabled end}}}
    menu:onMenuSelect(menu.item_table[1])
    assert.are.equal(menu,callback_menu)
    assert.are.equal("☑ Tracking",menu.item_table[1].text_func())
    assert.are.equal(0,closes)
    menu:onMenuSelect(menu.item_table[1])
    assert.are.equal("☐ Tracking",menu.item_table[1].text_func())
  end)

  it("does not execute a disabled action or its hold callback", function()
    local calls=0
    local menu=ActionMenu:new {item_table={{text="Link",enabled_func=function() return false end,
      callback=function() calls=calls+1 end,hold_callback=function() calls=calls+1 end}}}
    menu:onMenuSelect(menu.item_table[1]); menu:onMenuHold(menu.item_table[1])
    assert.are.equal(0,calls)
    assert.is_true(menu.item_table[1].dim)
  end)

  it("loads a submenu once and refreshes its parent after navigating back", function()
    local loads, value=0,0
    local menu=ActionMenu:new {title="StoryGraph", item_table={items_func=function()
      return {{text="Status "..value,sub_item_table_func=function(m)
        assert.is_table(m); loads=loads+1
        return {{text="Read",checked_func=function() return value==1 end,
          callback=function() value=1 end}}
      end}}
    end}}
    menu:onMenuSelect(menu.item_table[1])
    menu:onMenuSelect(menu.item_table[1])
    assert.are.equal(1,loads)
    menu:onClose()
    assert.are.equal("StoryGraph",menu.title)
    assert.are.equal("Status 1  ›",menu.item_table[1].text_func())
  end)

  it("retains titles and callbacks while navigating nested submenus", function()
    local menu=ActionMenu:new {title="Settings",item_table={{text="Account",
      sub_item_table={{text="Token",sub_item_table={{text="Save",callback=function() end}}}}}}}
    menu:onMenuSelect(menu.item_table[1]); menu:onMenuSelect(menu.item_table[1])
    assert.are.equal("Token",menu.title)
    menu:onClose(); assert.are.equal("Account",menu.title)
    menu:onClose(); assert.are.equal("Settings",menu.title)
  end)

  it("allows explicit dismissal from review callbacks without closing twice", function()
    local closes=0
    local menu=ActionMenu:new {close_callback=function() closes=closes+1 end,
      item_table={{text="Review",sub_item_table={{text="Cancel",callback=function(m) m:closeMenu() end}}}}}
    menu:onMenuSelect(menu.item_table[1]); menu:onMenuSelect(menu.item_table[1])
    assert.are.equal(1,closes)
  end)

  it("keeps hold actions in the live settings menu", function()
    local value, received=true,nil
    local menu=ActionMenu:new {item_table={{text="Linked book",hold_callback=function(m)
      received=m;value=false;m:updateItems()
    end,checked_func=function() return value end}}}
    menu:onMenuHold(menu.item_table[1])
    assert.are.equal(menu,received)
    assert.are.equal("☐ Linked book",menu.item_table[1].text_func())
    assert.is_nil(menu._closed)
  end)
end)
