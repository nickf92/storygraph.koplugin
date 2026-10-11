local Button = require("ui/widget/button")
local ConfirmBox = require("ui/widget/confirmbox")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local InputDialog = require("ui/widget/inputdialog")
local InputText = require("ui/widget/inputtext")
local Size = require("ui/size")
local ToggleSwitch = require("ui/widget/toggleswitch")
local DateTimeWidget = require("ui/widget/datetimewidget")
local UpdateDoubleSpinWidget = require("storygraph/lib/ui/update_double_spin_widget")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local _ = require("gettext")
local T = require("ffi/util").template
local logger = require("logger")

local JournalDialog = InputDialog:extend {
  allow_newline = true,
  results = {},
  title = _("StoryGraph: Progress and notes"),
  input_hint = _("Note (optional)"),
  padding = 10,

  page = nil, -- current mapped value (percent or page)
  remote_page = nil, -- raw remote page count
  remote_percent = nil, -- initial remote percentage
  progress_type = "percentage",
  book_id = nil,
  date = nil, -- table with day, month, year
}
  
function JournalDialog:onConfigChoose(key, value)
  -- Recalculate self.page based on the new type
  local current_local = self.page_mapper.ui:getCurrentPage()
  local total_local = self.page_mapper.ui.document:getPageCount()
  local remote_total = self.remote_page
  if self.progress_type == "percentage" then
    self.page = math.floor((current_local / total_local) * 100 + 0.5)
  else
    self.page = self.page_mapper:getMappedPage(current_local, total_local, remote_total)
  end
  self.page_button:setText(self.page_button.text_func(self), self.page_button.width)
  UIManager:setDirty(self.page_button, "partial")
end

function JournalDialog:init(reinit)
  self:setModified()
  self.date = self.date or os.date("*t")

  local journal_self = self
  local confirm_bypass = false
  self.save_callback = function() 
    local remote_val = journal_self.remote_percent or 0
    local current_pct
    if journal_self.progress_type == "percentage" then
      current_pct = journal_self.page
    else
      local total_remote = journal_self.remote_page or 1
      current_pct = math.floor((journal_self.page / total_remote) * 100 + 0.5)
    end

    local save_data = {
      book_id = journal_self.book_id,
      text = journal_self.note_input:getText(),
      progress = journal_self.page,
      progress_type = journal_self.progress_type,
      date = journal_self.date
    }

    if not confirm_bypass and remote_val > current_pct then
      local confirm = ConfirmBox:new{
        text = _("Your selection (" .. current_pct .. "%) is behind your current StoryGraph progress (" .. remote_val .. "%). Are you sure you want to save?"),
        ok_text = _("Save anyway"),
        cancel_text = _("Cancel"),
        ok_callback = function()
          confirm_bypass = true
          journal_self.save_dialog_callback(save_data)
        end,
        cancel_callback = function()
          journal_self:setModified()
          UIManager:nextTick(function()
            UIManager:setDirty(nil, "full")
          end)
        end
      }
      UIManager:show(confirm)
      return true -- prevent closing for now
    end

    journal_self.save_dialog_callback(save_data)
  end -- Satisfy InputDialog
  InputDialog.init(self, reinit)
  self.note_input = self._input_widget
  self._note_container = self.vgroup[3]
  self._note_focus_row = self.layout[1]
  if reinit and self._added_widgets then
    self:moveNoteBelowControls()
    return
  end
  local gap = Size.span.horizontal_default
  local control_width = (self:getAddedWidgetAvailableWidth() - gap) / 2

  -- Progress Button
  self.page_button = Button:new {
    text_func = function()
      if self.progress_type == "percentage" then
        return _("Progress: " .. self.page .. "%")
      else
        return _("Page: " .. self.page .. " / " .. (self.remote_page or "?"))
      end
    end,
    width = control_width,
    text_font_size = 18,
    bordersize = Size.border.thin,
    callback = function()
      local current_page = self.page_mapper.ui:getCurrentPage()
      local total_pages = self.page_mapper.ui.document:getPageCount()
      local remote_pages = self.remote_page

      local display_local_page
      if self.progress_type == "percentage" then
        display_local_page = math.floor((self.page / 100) * total_pages + 0.5)
      else
        display_local_page = self.page_mapper:getUnmappedPage(self.page, total_pages, remote_pages)
      end

      local spinner = UpdateDoubleSpinWidget:new {
        ok_always_enabled = true,
        left_text = self.progress_type == "percentage" and "Percentage" or "Edition page",
        left_value = self.page,
        left_min = 0,
        left_max = self.progress_type == "percentage" and 100 or (remote_pages or 9999),
        left_step = 1,
        left_hold_step = 20,

        right_text = "Local page",
        right_value = display_local_page,
        right_max = total_pages,
        right_step = 1,
        right_hold_step = 20,

        update_callback = function(new_remote_val, new_local_val, remote_changed)
          if remote_changed then
            local mapped_local
            if self.progress_type == "percentage" then
              mapped_local = math.floor((new_remote_val / 100) * total_pages + 0.5)
            else
              mapped_local = self.page_mapper:getUnmappedPage(new_remote_val, total_pages, remote_pages)
            end
            return new_remote_val, mapped_local
          else
            local mapped_remote
            if self.progress_type == "percentage" then
              mapped_remote = math.floor((new_local_val / total_pages) * 100 + 0.5)
            else
              mapped_remote = self.page_mapper:getMappedPage(new_local_val, total_pages, remote_pages)
            end
            return mapped_remote, new_local_val
          end
        end,
        ok_text = _("Set progress"),
        title_text = _("Set current progress"),
        callback = function(remote_val, _local_val)
          self.page = remote_val
          self.page_button:setText(self.page_button.text_func(self), self.page_button.width)
        end
      }
      self:onCloseKeyboard()
      UIManager:show(spinner)
    end
  }



  -- Progress Type Toggle
  local progress_type_toggle = ToggleSwitch:new {
    width = self:getAddedWidgetAvailableWidth(),
    margin = Size.margin.default,
    alternate = false,
    toggle = { _("Percentage"), _("Edition page") },
    values = { "percentage", "pages" },
    config = self,
    callback = function(position)
      local old_type = self.progress_type
      self.progress_type = position == 1 and "percentage" or "pages"
      if old_type ~= self.progress_type then
        self:onConfigChoose()
      end
    end,
  }
  progress_type_toggle:setPosition(self.progress_type == "percentage" and 1 or 2)
  self:addWidget(progress_type_toggle)

  -- Date Button (triggers DateTimeWidget)
  self.date_button = Button:new {
    text_func = function()
      return T(_("Date: %1"), string.format("%04d-%02d-%02d", self.date.year, self.date.month, self.date.day))
    end,
    width = control_width,
    text_font_size = 18,
    bordersize = Size.border.thin,
    callback = function()
      local date_picker = DateTimeWidget:new{
        year = self.date.year,
        month = self.date.month,
        day = self.date.day,
        ok_text = _("Set date"),
        title_text = _("Set date"),
        info_text = _("The date format is year, month, day."),
        callback = function(picker)
          self.date = {
            year = picker.year,
            month = picker.month,
            day = picker.day
          }
          self.date_button:setText(self.date_button.text_func(self), self.date_button.width)
        end
      }
      self:onCloseKeyboard()
      UIManager:show(date_picker)
    end
  }

  local control_row = FrameContainer:new {
    padding_top = Size.padding.default,
    padding_bottom = Size.padding.default,
    bordersize = 0,
    HorizontalGroup:new {
      self.page_button,
      HorizontalSpan:new { width = gap },
      self.date_button
    }
  }

  self:addWidget(control_row)
  -- Retain controls while releasing the first layout, then measure the input
  -- with both controls included in the available height (also on small screens).
  for _ = 1, #self._added_widgets do table.remove(self.vgroup, #self.vgroup - 2) end
  self:free()
  -- Enable adaptive sizing only after both controls have been registered:
  -- addWidget would otherwise re-init midway through constructing them.
  -- InputDialog reserves the keyboard, controls and submit-button heights.
  self.use_available_height = true
  self.text_height = nil
  InputDialog.init(self, true)
  self.note_input = self._input_widget
  self._note_container = self.vgroup[3]
  self._note_focus_row = self.layout[1]
  self:moveNoteBelowControls()
end

-- InputDialog adds controls below the input. Move the input as a single unit,
-- including its focus row, then restore its native order before re-init/free.
function JournalDialog:moveNoteBelowControls()
  table.remove(self.vgroup, 3)
  table.insert(self.vgroup, 3 + #self._added_widgets, self._note_container)
  table.remove(self.layout, 1)
  table.insert(self.layout, #self.layout, self._note_focus_row)
  if self.selected then
    if self.selected.y == 1 then
      self.selected.y = #self.layout - 1
    elseif self.selected.y < #self.layout then
      self.selected.y = self.selected.y - 1
    end
  end
  self._note_below_controls = true
end

function JournalDialog:restoreInputOrder()
  if not self._note_below_controls then return end
  for i, widget in ipairs(self.vgroup) do
    if widget == self._note_container then
      table.remove(self.vgroup, i)
      table.insert(self.vgroup, 3, widget)
      break
    end
  end
  for i, row in ipairs(self.layout) do
    if row == self._note_focus_row then
      if self.selected then
        if self.selected.y == i then
          self.selected.y = 1
        elseif self.selected.y < i then
          self.selected.y = self.selected.y + 1
        end
      end
      table.remove(self.layout, i)
      table.insert(self.layout, 1, row)
      break
    end
  end
  self._note_below_controls = false
end

function JournalDialog:reinit()
  self:restoreInputOrder()
  return InputDialog.reinit(self)
end

JournalDialog.onKeyboardHeightChanged = JournalDialog.reinit

function JournalDialog:free()
  self:restoreInputOrder()
  return InputDialog.free(self)
end

function JournalDialog:setModified()
  if self.input then
    self._text_modified = true
    if self.button_table then
      self.button_table:getButtonById("save"):enable()
      self:refreshButtons()
    end
  end
end

function JournalDialog:onSwitchFocus(inputbox)
  self._input_widget:unfocus()
  self:onCloseKeyboard()
  UIManager:setDirty(nil, function()
    return "ui", self.dialog_frame.dimen
  end)
  self._input_widget = inputbox
  self._input_widget:focus()
  self.focused_field_idx = inputbox.idx
  if (Device:hasKeyboard() or Device:hasScreenKB()) and G_reader_settings:isFalse("virtual_keyboard_enabled") then
    return
  end
  self:onShowKeyboard()
end

return JournalDialog
