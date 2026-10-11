local loadUI = require("spec/support/load_ui")

-- Match native Menu's navigation contract; drawing is a device smoke test.
local NativeMenu = {}
function NativeMenu.getMenuText(item)
  local text = item.text_func and item.text_func() or item.text
  if item.sub_item_table or item.sub_item_table_func then text = text .. " ▸" end
  return text
end
function NativeMenu:extend(class) return setmetatable(class, {__index = self}) end
function NativeMenu:new(options)
  local menu = setmetatable(options, {__index = self})
  menu:init()
  return menu
end
function NativeMenu:init()
  -- Native setupItemHeights runs during init, before updateItems, and reads text.
  for _, item in ipairs(self.item_table) do
    assert(type(item.text) == "string", "Native height calculation requires item.text")
  end
  self.item_table_stack = {}
  self.inner_dimen = self.inner_dimen or {w=400}
  self.available_height = self.available_height or 600
  self.linesize = 1
  self.font_size = self.items_font_size or 19
  self:updateItems()
end
function NativeMenu:setupItemHeights()
  self.page_items = {{}}
  for i, item in ipairs(self.item_table) do
    item.height = 25
    self.page_items[1][i] = i
  end
end
function NativeMenu:updateItems()
  self:setupItemHeights()
  self.rendered = {}
  for _, item in ipairs(self.item_table) do
    assert(type(item.text) == "string", "Native height calculation requires item.text")
    self.rendered[#self.rendered + 1] = NativeMenu.getMenuText(item)
  end
  self.render_count = (self.render_count or 0) + 1
end
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
  ["ui/font"] = {getFace=function(_, name, size) return {orig_size=size or 22} end},
  ["ui/size"] = {item={height_large=50},span={vertical_default=2,horizontal_default=10},padding={fullscreen=15}},
  ["ui/widget/textboxwidget"] = {new=function(_, options)
    local lines = 0
    for line in (options.text .. "\n"):gmatch("(.-)\n") do
      lines = lines + math.max(1, math.ceil(#line * 10 / (options.width or 400)))
    end
    return {getSize=function() return {h=lines*22} end, free=function() end}
  end},
})

describe("StoryGraph action menu navigation", function()
  it("uses the original touch-menu font and minimum height for actions", function()
    local menu=ActionMenu:new {item_table={
      {text="Progress",callback=function() end},
      {text="Disabled action",enabled=false,callback=function() end},
      {text="Tracking",checked_func=function() return true end},
    }}
    assert.are.equal(22, menu.items_font_size)
    for _,item in ipairs(menu.item_table) do assert.is_true(item.height>=50) end
  end)

  it("measures summary lines and keeps section headings as tall as touch rows", function()
    local menu=ActionMenu:new {item_table={
      {text="Book\nPaperback\nTracking on",is_header=true},
      {text="Reading",is_header=true},
      {text="Progress",callback=function() end},
    }}
    assert.are.equal(71,menu.item_table[1].height)
    assert.are.equal(menu.item_table[3].height,menu.item_table[2].height)
  end)

  it("paginates touch rows without empty pages or missing entries", function()
    local menu=ActionMenu:new {available_height=100,item_table={
      {text="One"},{text="Two"},{text="Three"},
    }}
    assert.are.same({{1,2},{3}},menu.page_items)
    menu.item_table={};menu:updateItems()
    assert.are.same({{}},menu.page_items)
  end)

  it("remeasures wrapped labels when the menu width changes", function()
    local menu=ActionMenu:new {item_table={{text="A long edition label that needs wrapping"}}}
    local height=menu.item_table[1].height
    menu.inner_dimen.w=160
    menu:updateItems()
    assert.is_true(menu.item_table[1].height>height)
  end)

  it("materializes dynamic labels before native height calculation and refreshes them", function()
    local count = 2
    local menu = ActionMenu:new {item_table={
      {text_func=function() return "Book\nPaperback\nAutomatic tracking on" end},
      {text_func=function() return "Pending synchronization (" .. count .. ")" end,
        sub_item_table={{text="Pending"}}},
    }}
    assert.are.equal("Book\nPaperback\nAutomatic tracking on", menu.item_table[1].text)
    assert.are.equal("Pending synchronization (2) ▸", menu.rendered[2])
    count = 3
    menu:updateItems()
    assert.are.equal("Pending synchronization (3)", menu.item_table[2].text)
    assert.are.equal("Pending synchronization (3) ▸", menu.rendered[2])
  end)

  it("keeps checkbox changes open and refreshes their displayed state", function()
    local enabled, callback_menu, closes = false, nil, 0
    local menu = ActionMenu:new {title="Settings", close_callback=function() closes=closes+1 end,
      item_table={{text="Tracking",checked_func=function() return enabled end,
        callback=function(m) callback_menu=m; enabled=not enabled end}}}
    assert.are.equal("☐ Tracking",menu.item_table[1].text)
    menu:onMenuSelect(menu.item_table[1])
    assert.are.equal(menu,callback_menu)
    assert.are.equal("☑ Tracking",menu.item_table[1].text_func())
    assert.are.equal("☑ Tracking",menu.item_table[1].text)
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
    assert.are.equal("Status 1",menu.item_table[1].text_func())
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
