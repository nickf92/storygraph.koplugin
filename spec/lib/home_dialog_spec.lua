local loadUI = require("spec/support/load_ui")

describe("StoryGraph home screen", function()
  local Home, shown, closed, dirty, screen_height, calls, items
  local widgets
  before_each(function()
    shown, closed, dirty, calls, widgets = {}, {}, 0, {}, {}
    screen_height = 800
    local Widget = {}
    function Widget:extend(class) return setmetatable(class, {__index=self}) end
    function Widget:new(options)
      options = setmetatable(options or {}, {__index=self})
      if options.init then options:init() end
      return options
    end
    function Widget:getSize()
      if self.dimen then return self.dimen end
      local height = 0
      for _, child in ipairs(self) do height = height + child:getSize().h end
      return {w=self.width or 400, h=self.height or height}
    end
    function Widget:free()
      for _,child in ipairs(self) do child:free() end
    end
    local Text = Widget:extend {}
    function Text:init()
      widgets[#widgets+1] = self
      local lines = 0
      for line in (self.text .. "\n"):gmatch("(.-)\n") do
        lines = lines + math.max(1, math.ceil(#line*10/self.width))
      end
      self.height = lines * self.face.size
    end
    local Button = Widget:extend {}
    function Button:init()
      self.label_widget = {}
    end
    local Span = Widget:extend {}
    function Span:getSize() return {w=0,h=self.width} end
    local Title = Widget:extend {height=50}
    function Title:generateHorizontalLayout() return {{self}} end
    local Scroll = Widget:extend {}
    function Scroll:getScrollbarWidth() return 18 end
    function Scroll:_scrollBy() end
    local device = {screen={getWidth=function() return 600 end,scaleBySize=function(_,size) return size end,
      getHeight=function() return screen_height end,
      getSize=function() return {w=600,h=screen_height} end},
      hasKeys=function() return true end, input={group={Back={"Back"}}}}
    Home = loadUI("storygraph/lib/ui/home_dialog.lua", {
      ["ffi/blitbuffer"]={COLOR_BLACK=0,COLOR_WHITE=1,COLOR_LIGHT_GRAY=2,COLOR_DARK_GRAY=3,COLOR_GRAY=4},
      device=device, ["ui/font"]={getFace=function(_,_,size) return {size=size} end},
      ["ui/size"]={padding={fullscreen=15,large=10,default=5},border={window=1,button=1,thin=0.5},line={thin=1},
        radius={window=4},span={vertical_large=5},item={height_large=50}},
      ["ui/geometry"]={new=function(_,options) return options end},
      ["ui/widget/button"]=Button,["ui/widget/container/centercontainer"]=Widget,
      ["ui/widget/container/framecontainer"]=Widget,["ui/widget/container/scrollablecontainer"]=Scroll,
      ["ui/widget/horizontalgroup"]=Widget,["ui/widget/horizontalspan"]=Widget,
      ["ui/widget/imagewidget"]=Widget,
      ["ui/widget/container/rightcontainer"]=Widget,["ui/widget/overlapgroup"]=Widget,
      ["ui/widget/linewidget"]=Widget,["ui/widget/textwidget"]=Widget,
      ["ui/widget/focusmanager"]=Widget,["ui/widget/textboxwidget"]=Text,
      ["ui/widget/titlebar"]=Title,["ui/widget/verticalgroup"]=Widget,["ui/widget/verticalspan"]=Span,
      ["ui/uimanager"]={show=function(_,widget) shown[#shown+1]=widget end,
        close=function(_,widget) closed[#closed+1]=widget end,setDirty=function() dirty=dirty+1 end},
      ["storygraph/lib/ui/action_menu"]=Widget,
    })
    items={
      {text="Book title\nPaperback · Reading\nAutomatic tracking on",is_summary=true,is_header=true},
      {text="Reading",is_header=true},
      {text="Progress and notes",primary=true,keep_menu_open=true,
        callback=function(menu) calls.progress=menu end},
      {text="Status and review",sub_item_table_func=function(menu)
        calls.status=(calls.status or 0)+1; calls.parent=menu
        return {{text="Read"}}
      end,refresh_items_func=function() return {{text="Reading"}} end},
      {text="Jump",callback=function(menu) calls.jump=menu end},
      {text="Synchronization",is_header=true},
      {text="Pending synchronization (0)",sub_item_table={{text="No pending synchronization"}}},
    }
  end)

  local function create(Home, items)
    return Home:new {title="StoryGraph",items_func=function() return items end,
      onLeftButtonTap=function(menu) menu.settings_opened=true end}
  end

  it("separates book title and details and emphasizes the primary touch button",function()
    local home=create(Home,items)
    local title=home.book_card[1][3][1]
    local details=home.book_card[1][3][3]
    assert.are.equal("Book title",title.text)
    assert.are.equal(26,title.face.size)
    assert.are.equal("Paperback · Reading\nAutomatic tracking on",details.text)
    assert.are.equal(20,details.face.size)
    assert.are.equal(0,details.fgcolor)
    assert.are.equal(0.5,home.book_card.bordersize)
    assert.are.equal(4,#home.action_buttons)
    local primary=home.action_buttons[1]
    assert.are.equal(0,primary.background)
    assert.are.equal(1,primary.label_widget.fgcolor)
    assert.is_true(primary.text_font_bold)
    for _,button in ipairs(home.action_buttons) do assert.is_true(button.height>=50) end
  end)

  it("keeps sync details outside the cover card at full content width",function()
    local home=create(Home,items)
    local card_height=home.book_card:getSize().h
    items[1].sync_text_func=function() return "Last synced progress: 47.0%\nSynced on: 11/10/2026 21:40" end
    home:updateItems()
    assert.are.equal(card_height,home.book_card:getSize().h)
    local sync_widget
    for _,widget in ipairs(widgets) do
      if widget.text==items[1].sync_text_func() then sync_widget=widget end
    end
    assert.is_not_nil(sync_widget)
    assert.are.equal(home.book_card.width,sync_widget.width)
    assert.are.equal(18,sync_widget.face.size)
    assert.are.equal(0,sync_widget.fgcolor)
    local body=home.scroller[1][1]
    local card_index,sync_index,heading_index,reading_index
    for i,widget in ipairs(body) do
      if widget==home.book_card then card_index=i end
      if widget.text=="Last synchronization" then
        heading_index=i
        assert.are.equal(16,widget.face.size)
        assert.are.equal(3,widget.fgcolor)
      end
      if widget.text=="Reading" then reading_index=i end
      if widget==sync_widget then
        sync_index=i
        assert.is_nil(widget.background)
      end
    end
    assert.is_true(card_index<heading_index and heading_index<sync_index and sync_index<reading_index)
  end)

  it("uses a local cover with aspect-ratio scaling and disposable ownership",function()
    local image={}
    local reads=0
    local home=Home:new {title="StoryGraph",
      document={getCoverPageImage=function() reads=reads+1; return image end},
      items_func=function() return items end,onLeftButtonTap=function() end}
    local cover=home.book_card[1][1][1]
    assert.are.equal(image,cover.image)
    assert.is_true(cover.image_disposable)
    assert.are.equal(0,cover.scale_factor)
    assert.are.equal(80,cover.width)
    assert.are.equal(120,cover.height)
    assert.are.equal(1,reads)
  end)

  it("keeps the book card centered including the reserved scrollbar space",function()
    local home=create(Home,items)
    local body=home.scroller[1]
    local left=body.padding_left or body.padding
    local right=home.scroller.dimen.w-left-home.book_card.width
    assert.are.equal(left,right)
    assert.are.equal("left",home.book_card[1][3][1].alignment)
    assert.are.equal("left",home.book_card[1][3][3].alignment)
  end)

  it("keeps the book card usable when local cover extraction fails",function()
    local home=Home:new {title="StoryGraph",
      document={getCoverPageImage=function() error("No embedded cover") end},
      items_func=function() return items end,onLeftButtonTap=function() end}
    assert.are.equal("No cover",home.book_card[1][1][1][1].text)
    assert.are.equal(4,#home.action_buttons)
  end)

  it("shows the progress and optional-note explanation without changing the action",function()
    items[3].help_text="Update progress, or add a note (optional)."
    local home=create(Home,items)
    local hint
    for _,widget in ipairs(widgets) do
      if widget.text==items[3].help_text then hint=widget end
    end
    assert.is_not_nil(hint)
    home.action_buttons[1].callback()
    assert.are.equal(home,calls.progress)
  end)

  it("uses borderless secondary rows with aligned labels and separate arrows",function()
    local home=create(Home,items)
    assert.are.equal(1,home.action_buttons[1].bordersize)
    for i=2,#home.action_buttons do
      local button=home.action_buttons[i]
      assert.are.equal(0,button.bordersize)
      assert.is_nil(button.background)
      assert.is_nil(button.text:find("▸",1,true))
      assert.is_true(button.padding_h>=10)
    end
    assert.are.equal(home.action_buttons[2].padding_h,home.action_buttons[3].padding_h)
    home.action_buttons[2].callback()
    assert.are.equal(1,calls.status)
  end)

  it("retains settings access and live progress callbacks",function()
    local home=create(Home,items)
    home.title_bar.left_icon_tap_callback()
    assert.is_true(home.settings_opened)
    home.action_buttons[1].callback()
    assert.are.equal(home,calls.progress)
    assert.is_nil(home._closed)
    assert.is_true(dirty>0)
  end)

  it("refreshes after closing a submenu without loading it during redraw",function()
    local home=create(Home,items)
    assert.is_nil(calls.status)
    home.action_buttons[2].callback()
    assert.are.equal(1,calls.status)
    assert.are.equal(home,calls.parent)
    assert.are.equal("Status and review",shown[1].title)
    assert.are.equal(items[4].refresh_items_func,shown[1].item_table.items_func)
    shown[1].close_callback()
    assert.are.equal(1,calls.status)
    assert.is_true(dirty>0)
  end)

  it("blocks disabled actions and preserves dismissal after jumping",function()
    local home=create(Home,items)
    items[3].enabled_func=function() return false end
    home:activate(items[3]); assert.is_nil(calls.progress)
    home:activate(items[5]); assert.are.equal(home,calls.jump)
    assert.is_true(home._closed)
    home:onClose(); assert.are.equal(1,#closed)
  end)

  it("keeps settings and synchronization available without a document",function()
    local home=create(Home,{items[6],items[7]})
    assert.are.equal(1,#home.action_buttons)
    home.action_buttons[1].callback()
    assert.are.equal("No pending synchronization",shown[1].item_table[1].text)
    home.title_bar.left_icon_tap_callback(); assert.is_true(home.settings_opened)
  end)

  it("recalculates the scroll viewport on small screens and rotation",function()
    screen_height=240
    local home=create(Home,items)
    assert.are.equal(188,home.scroller.dimen.h)
    assert.is_true(home.scroller[1]:getSize().h>home.scroller.dimen.h)
    screen_height=400
    home:onScreenResize()
    assert.are.equal(348,home.scroller.dimen.h)
    assert.are.same({{{"Back"}}},home.key_events.Close)
  end)

  it("preserves focus-manager keyboard navigation bindings",function()
    local keys={FocusDown={{"Down"}}}
    local home=Home:new {title="StoryGraph",key_events=keys,
      items_func=function() return items end,onLeftButtonTap=function() end}
    assert.are.same({{"Down"}},home.key_events.FocusDown)
    home:updateItems()
    assert.are.same({{"Down"}},home.key_events.FocusDown)
  end)
end)
