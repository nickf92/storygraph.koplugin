local loadUI = require("spec/support/load_ui")
local Widget={}
function Widget:new(o) return setmetatable(o or {},{__index=self}) end
function Widget:setText(text) self.text=text end
function Widget:setPosition(position) self.position=position end
function Widget:getSize() return {h=40} end
local InputDialog=setmetatable({},{__index=Widget})
function InputDialog:extend(class) return setmetatable(class,{__index=self}) end
function InputDialog:init()
  self.width=400
  -- Model InputDialog's sizing contract: explicit text_height bypasses the
  -- keyboard/chrome/added-widget budget, unless fullscreen is requested.
  if self.orig_text_height==nil then self.orig_text_height=self.text_height or false end
  local controls_height=0
  for _,widget in ipairs(self._added_widgets or {}) do
    controls_height=controls_height+widget:getSize().h
  end
  local available_height=(self.screen_height or 600)-(self.keyboard_height or 300)-100-controls_height
  if not self.text_height or self.fullscreen then
    self.text_height=self.use_available_height and available_height or math.min(20,available_height)
  end
  self.frame_height=100+controls_height+self.text_height
  self._input_widget={getText=function() return self.input or "" end}
  self.vgroup={{name="title"},{name="spacer"},{self._input_widget},{name="spacer"},{name="buttons"}}
  self.layout={{self._input_widget},{name="buttons"}}
  self.selected={x=1,y=1}
  for _,widget in ipairs(self._added_widgets or {}) do self:addWidget(widget,true) end
end
function InputDialog:addWidget(widget,reinit)
  self._added_widgets=self._added_widgets or {}
  if not reinit then table.insert(self._added_widgets,widget) end
  table.insert(self.vgroup,#self.vgroup-1,widget)
  table.insert(self.layout,#self.layout,{widget})
end
function InputDialog:getAddedWidgetAvailableWidth() return 360 end
function InputDialog:onCloseKeyboard() end
function InputDialog:free()
  assert.are.equal(self._input_widget,self.vgroup[3][1])
end
function InputDialog:reinit()
  assert.are.equal(self._input_widget,self.vgroup[3][1])
  self.input=self._input_widget:getText()
  for _=1,#self._added_widgets do table.remove(self.vgroup,#self.vgroup-2) end
  self:free()
  self.text_height=self.orig_text_height or nil
  self:init(true)
end

local shown={}
local Journal=loadUI("storygraph/lib/ui/journal_dialog.lua",{
  ["ui/widget/inputdialog"]=InputDialog,
  ["ui/widget/button"]=Widget,
  ["ui/widget/confirmbox"]=Widget,["ui/widget/container/framecontainer"]=Widget,
  ["ui/widget/horizontalgroup"]=Widget,["ui/widget/horizontalspan"]=Widget,
  ["ui/widget/toggleswitch"]=Widget,["ui/widget/datetimewidget"]=Widget,
  ["storygraph/lib/ui/update_double_spin_widget"]=Widget,
  ["ui/font"]={getFace=function() return {} end},
  ["ui/size"]={border={thin=1},span={horizontal_default=10},margin={default=10},padding={default=10}},
  device={screen={scaleBySize=function(_,value) return value end}},
  ["ui/uimanager"]={show=function(_,o) shown[#shown+1]=o end,setDirty=function() end,nextTick=function(_,job) job() end},
})

describe("Progress and notes dialog",function()
  local dialog,saved
  before_each(function()
    shown,saved={},nil
    dialog=setmetatable({input="A note",input_box_height=250,book_id="book",page=42,remote_page=200,remote_percent=37,
      date={year=2026,month=10,day=11},progress_type="percentage",
      page_mapper={ui={getCurrentPage=function() return 42 end,
        document={getPageCount=function() return 100 end}},
        getMappedPage=function(_,local_page,total,pages) return local_page/total*pages end,
        getUnmappedPage=function(_,page,total,pages) return page/pages*total end},
      save_dialog_callback=function(data) saved=data end},{__index=Journal})
    dialog:init()
  end)

  it("keeps the note and submit buttons above the keyboard on initial opening",function()
    assert.is_true(dialog.frame_height<=600-300)
    assert.is_true(dialog.text_height>0)
  end)

  it("recomputes space when keyboard height changes without losing the draft",function()
    dialog.note_input.getText=function() return "Unsaved draft" end
    dialog.page=55
    dialog.keyboard_height=360
    dialog:onKeyboardHeightChanged()
    assert.is_true(dialog.frame_height<=600-360)
    assert.are.equal("Unsaved draft",dialog.note_input:getText())
    assert.are.equal(55,dialog.page)
    dialog.keyboard_height=0
    dialog:onKeyboardHeightChanged()
    assert.is_true(dialog.frame_height<=600)
    assert.are.equal("Unsaved draft",dialog.note_input:getText())
  end)

  it("places both controls before the note and keeps focus in visual order",function()
    assert.are.equal(2,#dialog._added_widgets)
    assert.are.equal(dialog._added_widgets[1],dialog.vgroup[3])
    assert.are.equal(dialog._added_widgets[2],dialog.vgroup[4])
    assert.are.equal(dialog.note_input,dialog.vgroup[5][1])
    assert.are.equal(dialog.note_input,dialog.layout[#dialog.layout-1][1])
    assert.are.equal(dialog.note_input,dialog.layout[dialog.selected.y][1])
  end)

  it("preserves text, selected progress and date on keyboard-height reinitialization",function()
    dialog.page=55
    dialog.date={year=2026,month=10,day=9}
    dialog:onKeyboardHeightChanged()
    assert.are.equal(2,#dialog._added_widgets)
    assert.are.equal("A note",dialog.note_input:getText())
    assert.are.equal(55,dialog.page)
    assert.are.equal(9,dialog.date.day)
    assert.are.equal(dialog.note_input,dialog.vgroup[5][1])
    dialog:free()
  end)

  it("keeps the note payload and requires confirmation for backward progress",function()
    dialog.remote_percent=60
    dialog.save_callback()
    assert.is_nil(saved)
    assert.are.equal("Save anyway",shown[1].ok_text)
    shown[1].ok_callback()
    assert.are.same({book_id="book",text="A note",progress=42,progress_type="percentage",date=dialog.date},saved)
  end)

  it("still accepts progress-only updates with an empty note",function()
    dialog.input=""
    dialog.save_callback()
    assert.are.equal("",saved.text)
    assert.are.equal(42,saved.progress)
  end)

  it("keeps both picker conversion directions and the selected unit",function()
    dialog.page_button.callback()
    local picker=shown[1]
    local percent,local_page=picker.update_callback(50,42,true)
    assert.are.equal(50,percent);assert.are.equal(50,local_page)
    picker.callback(50,50);assert.are.equal(50,dialog.page)
    dialog._added_widgets[1].callback(2)
    assert.are.equal("pages",dialog.progress_type)
    assert.are.equal(84,dialog.page)
    dialog.page_button.callback();picker=shown[2]
    local edition_page
    edition_page,local_page=picker.update_callback(100,42,true)
    assert.are.equal(100,edition_page);assert.are.equal(50,local_page)
    edition_page,local_page=picker.update_callback(100,60,false)
    assert.are.equal(120,edition_page);assert.are.equal(60,local_page)
  end)
end)
