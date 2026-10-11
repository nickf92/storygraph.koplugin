local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local Font = require("ui/font")
local Size = require("ui/size")
local Geom = require("ui/geometry")
local Button = require("ui/widget/button")
local CenterContainer = require("ui/widget/container/centercontainer")
local FrameContainer = require("ui/widget/container/framecontainer")
local ScrollableContainer = require("ui/widget/container/scrollablecontainer")
local RightContainer = require("ui/widget/container/rightcontainer")
local FocusManager = require("ui/widget/focusmanager")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local ImageWidget = require("ui/widget/imagewidget")
local LineWidget = require("ui/widget/linewidget")
local OverlapGroup = require("ui/widget/overlapgroup")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget = require("ui/widget/textwidget")
local TitleBar = require("ui/widget/titlebar")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local UIManager = require("ui/uimanager")
local ActionMenu = require("storygraph/lib/ui/action_menu")
local _ = require("gettext")

local HomeDialog = FocusManager:extend {}

function HomeDialog:init()
  local screen = Device.screen
  local padding = Size.padding.fullscreen + Size.padding.large
  local width = screen:getWidth() - 2 * Size.border.window
  local scrollbar_width = ScrollableContainer:getScrollbarWidth()
  local side_margin = padding + math.ceil(scrollbar_width / 2)
  local content_width = width - 2 * side_margin
  self.dimen = Geom:new(screen:getSize())
  self.title_bar = TitleBar:new {
    width = width, title = self.title, fullscreen = true,
    with_bottom_line = true, left_icon = "appbar.settings", show_parent = self,
    left_icon_tap_callback = function() self.onLeftButtonTap(self) end,
    close_callback = function() self:onClose() end,
  }
  self.layout = self.title_bar:generateHorizontalLayout()
  self.action_buttons = {}
  self.book_card = nil
  local content = VerticalGroup:new { align = "left" }
  local function gap(height)
    content[#content + 1] = VerticalSpan:new { width = height }
  end
  local function text(value, size, bold, color)
    content[#content + 1] = TextBoxWidget:new {
      text = value, face = Font:getFace("smallinfofont", size),
      width = content_width, bold = bold, fgcolor = color, alignment = "left",
    }
  end
  local function separator()
    content[#content + 1] = LineWidget:new {
      background = Blitbuffer.COLOR_GRAY,
      dimen = Geom:new { w = content_width, h = Size.line.thin },
    }
  end
  for item_index, item in ipairs(self.items_func()) do
    local label = item.text_func and item.text_func() or item.text
    if item.is_summary then
      gap(Size.padding.large)
      local title, details = label:match("^([^\n]*)\n(.*)$")
      local card_padding = Size.padding.large
      local cover_width = math.min(screen:scaleBySize(80), math.floor(content_width / 4))
      local cover_height = math.floor(cover_width * 1.5)
      local cover
      if self.document and self.document.getCoverPageImage then
        local ok, image = pcall(self.document.getCoverPageImage, self.document)
        if ok and image then
          cover = ImageWidget:new { image = image, image_disposable = true,
            width = cover_width, height = cover_height, scale_factor = 0 }
        end
      end
      if not cover then
        cover = CenterContainer:new {
          dimen = Geom:new { w = cover_width, h = cover_height },
          TextBoxWidget:new { text = _("No cover"), width = cover_width,
            face = Font:getFace("smallinfofont", 16), alignment = "center" },
        }
      end
      local text_width = content_width - cover_width - 3 * card_padding - 4 * Size.border.thin
      local book = VerticalGroup:new { align = "left",
        TextBoxWidget:new { text = title or label, width = text_width,
          face = Font:getFace("smallinfofont", 26), bold = true, alignment = "left" },
      }
      if details then
        book[#book + 1] = VerticalSpan:new { width = Size.padding.large }
        book[#book + 1] = TextBoxWidget:new { text = details, width = text_width,
          face = Font:getFace("smallinfofont", 20), fgcolor = Blitbuffer.COLOR_BLACK,
          alignment = "left", justified = false }
      end
      self.book_card = FrameContainer:new {
        width = content_width, padding = card_padding, bordersize = Size.border.thin,
        color = Blitbuffer.COLOR_BLACK, background = Blitbuffer.COLOR_WHITE,
        HorizontalGroup:new { align = "top",
          FrameContainer:new { bordersize = Size.border.thin, padding = 0,
            color = Blitbuffer.COLOR_BLACK, cover },
          HorizontalSpan:new { width = card_padding }, book,
        },
      }
      content[#content + 1] = self.book_card
      local sync_details = item.sync_text_func and item.sync_text_func()
      if sync_details then
        gap(2 * Size.padding.large)
        text(_("Last synchronization"), 16, true, Blitbuffer.COLOR_DARK_GRAY)
        gap(Size.span.vertical_large)
        text(sync_details, 18, false, Blitbuffer.COLOR_BLACK)
      end
    elseif item.is_header then
      gap(2 * Size.padding.large)
      text(label, 16, true, Blitbuffer.COLOR_DARK_GRAY)
      gap(Size.span.vertical_large)
    else
      local enabled = item.enabled
      if item.enabled_func then enabled = item.enabled_func() end
      local has_submenu = item.sub_item_table or item.sub_item_table_func
      local inset = Size.padding.large
      local button = Button:new {
        text = label, width = content_width,
        height = Size.item.height_large, padding_v = Size.padding.default,
        padding_h = inset,
        bordersize = item.primary and Size.border.button or 0,
        text_font_face = "smallinfofont", text_font_size = 22,
        text_font_bold = item.primary == true,
        align = item.primary and "center" or "left", enabled = enabled ~= false,
        background = item.primary and (enabled ~= false and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_LIGHT_GRAY) or nil,
        callback = function() self:activate(item) end,
        show_parent = self,
      }
      if item.primary and enabled ~= false then
        button.label_widget.fgcolor = Blitbuffer.COLOR_WHITE
        if button.label_widget.update then button.label_widget:update() end
      end
      self.action_buttons[#self.action_buttons + 1] = button
      self.layout[#self.layout + 1] = { button }
      if has_submenu then
        content[#content + 1] = OverlapGroup:new {
          allow_mirroring = false, button,
          RightContainer:new {
            dimen = Geom:new { w = content_width - inset, h = button:getSize().h },
            TextWidget:new { text = "›", face = Font:getFace("smallinfofont", 26),
              fgcolor = Blitbuffer.COLOR_DARK_GRAY },
          },
        }
      else
        content[#content + 1] = button
      end
      if item.primary then
        gap(Size.padding.default)
        if item.help_text then text(item.help_text, 16, false, Blitbuffer.COLOR_BLACK) end
        gap(Size.padding.large)
      else
        separator()
      end
    end
  end
  gap(Size.padding.large)
  local available_height = screen:getHeight() - 2 * Size.border.window - self.title_bar:getSize().h
  -- Reserve room for scrolling without shifting visible content to the left.
  local body = FrameContainer:new { padding = 0, padding_left = side_margin,
    padding_right = side_margin - scrollbar_width,
    bordersize = 0, content }
  self.content_offset = self.title_bar:getSize().h
  self.scroller = ScrollableContainer:new {
    dimen = Geom:new { w = width, h = available_height }, show_parent = self, body,
  }
  self[1] = CenterContainer:new {
    dimen = screen:getSize(),
    FrameContainer:new {
      bordersize = Size.border.window, radius = Size.radius.window, padding = 0,
      background = Blitbuffer.COLOR_WHITE,
      VerticalGroup:new { self.title_bar, self.scroller },
    },
  }
  self.key_events = self.key_events or {}
  if Device:hasKeys() then self.key_events.Close = { { Device.input.group.Back } } end
end

function HomeDialog:activate(item)
  if self._closed or item.enabled == false or (item.enabled_func and not item.enabled_func()) then return end
  local children = item.sub_item_table_func and item.sub_item_table_func(self) or item.sub_item_table
  if children then
    children.items_func = item.refresh_items_func
    UIManager:show(ActionMenu:new {
      title = item.text_func and item.text_func() or item.text, item_table = children,
      close_callback = function() if not self._closed then self:updateItems() end end,
    })
  elseif item.callback then
    item.callback(self)
    if not self._closed then
      if item.keep_menu_open then self:updateItems() else self:onClose() end
    end
  end
end

function HomeDialog:updateItems()
  self:free()
  self:init()
  UIManager:setDirty(self, "ui")
end

function HomeDialog:onScreenResize()
  self:updateItems()
  return true
end

function HomeDialog:onShow()
  UIManager:setDirty(self, "ui")
end

function HomeDialog:onFocusMove(args)
  local result = FocusManager.onFocusMove(self, args)
  local focus = self:getFocusItem()
  if focus and focus.dimen and self.dimen then
    self.scroller:_scrollBy(0, focus.dimen.y - self.dimen.y - self.content_offset, true)
  end
  return result
end

function HomeDialog:onClose()
  if not self._closed then
    self._closed = true
    UIManager:close(self)
    UIManager:setDirty(nil, "ui")
  end
  return true
end

HomeDialog.closeMenu = HomeDialog.onClose
HomeDialog.onCloseAllMenus = HomeDialog.onClose

return HomeDialog
