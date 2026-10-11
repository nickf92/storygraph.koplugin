local Menu = require("ui/widget/menu")
local Font = require("ui/font")
local Size = require("ui/size")
local TextBoxWidget = require("ui/widget/textboxwidget")
local InfoMessage = require("ui/widget/infomessage")
local UIManager = require("ui/uimanager")

-- Render the plugin's TouchMenu-style actions in a multiline native Menu.
-- Preserve their callback contract, including checks, holds and live refreshes.
local ActionMenu = Menu:extend {
  single_line = false,
  items_max_lines = 4,
  items_font_size = Font:getFace("smallinfofont").orig_size,
}

function ActionMenu:init()
  self.items_func = self.item_table.items_func
  if self.items_func then self.item_table = self.items_func(self) end
  self:prepareItems()
  Menu.init(self)
end

function ActionMenu:switchItemTable(title, items, ...)
  if title then self.title = title end
  if items then self.items_func = items.items_func end
  return Menu.switchItemTable(self, title, items, ...)
end

function ActionMenu:prepareItems()
  self.item_table.items_func = self.items_func
  for _, item in ipairs(self.item_table) do
    local enabled = item.enabled
    if item.enabled_func then enabled = item.enabled_func() end
    item.dim = enabled == false and not item.is_header
    item.bold = item.is_header or item.primary
    if not item.original_text_func then
      local text, text_func = item.text, item.text_func
      item.original_text_func = text_func or function() return text end
      item.text_func = function()
        local label = item.original_text_func()
        if item.checked_func then
          local checked = item.checked_func()
          return (item.radio and (checked and "● " or "○ ")
            or (checked and "☑ " or "☐ ")) .. label
        end
        return label
      end
    end
    -- Native Menu estimates multiline heights from text, including during init.
    -- Its getMenuText adds the submenu arrow when painting the row.
    item.text = item.text_func()
  end
end

function ActionMenu:updateItems(select_number)
  if self.items_func then self.item_table = self.items_func(self) end
  self:prepareItems()
  return Menu.updateItems(self, select_number, false)
end

function ActionMenu:setupItemHeights()
  local face = Font:getFace("smallinfofont", self.font_size)
  local sample = TextBoxWidget:new { text = "A", face = face, for_measurement_only = true }
  local line_height = sample:getSize().h
  sample:free()
  local width = self.inner_dimen.w - 2 * Size.padding.fullscreen - (self.state_w or 0)
  if self.is_enable_shortcut then width = width - line_height - Size.span.horizontal_default end
  local page, page_height = {}, 0
  self.page_items = { page }
  for index, item in ipairs(self.item_table) do
    -- Measure wrapped text and explicit newlines, rather than estimating a
    -- single-line width. Native Menu uses these heights for drawing and taps.
    local text = TextBoxWidget:new {
      text = Menu.getMenuText(item), face = face, width = width,
      bold = item.bold, for_measurement_only = true,
    }
    local text_height = math.min(text:getSize().h, self.items_max_lines * line_height)
    text:free()
    item.height = text_height + 2 * Size.span.vertical_default + self.linesize
    item.height = math.max(item.height, Size.item.height_large)
    item.shortcut_icon_width = line_height
    if #page > 0 and page_height + item.height > self.available_height then
      page, page_height = {}, 0
      self.page_items[#self.page_items + 1] = page
    end
    page[#page + 1] = index
    page_height = page_height + item.height
  end
end

function ActionMenu:onMenuSelect(item)
  local enabled = item.enabled
  if item.enabled_func then enabled = item.enabled_func() end
  if enabled == false then return true end
  local items_func = item.sub_item_table_func
  local children = items_func and items_func(self) or item.sub_item_table
  if children then
    if #children > 0 then
      self.item_table.title = self.title
      table.insert(self.item_table_stack, self.item_table)
      children.items_func = item.refresh_items_func
      self:switchItemTable(item.original_text_func(), children)
    end
  elseif item.callback then
    item.callback(self)
    if not self._closed then
      if item.checked_func or item.keep_menu_open then
        self:updateItems()
      else
        self:onCloseAllMenus()
      end
    end
  end
  return true
end

function ActionMenu:onMenuHold(item)
  local enabled = item.enabled
  if item.enabled_func then enabled = item.enabled_func() end
  if enabled == false then return true end
  if item.hold_callback then
    item.hold_callback(self)
    if item.hold_keep_menu_open == false then self:onCloseAllMenus() end
  else
    UIManager:show(InfoMessage:new { text = item.original_text_func() })
  end
  return true
end

-- TouchMenu callbacks use onClose() to dismiss the entire menu (e.g. reviews).
-- Native Menu's close button and Back key instead navigate to the parent.
function ActionMenu:onCloseAllMenus()
  if self._closed then return true end
  self._closed = true
  return Menu.onCloseAllMenus(self)
end

function ActionMenu:closeMenu()
  return self:onCloseAllMenus()
end

return ActionMenu
