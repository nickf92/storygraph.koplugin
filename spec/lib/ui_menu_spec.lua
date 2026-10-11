local loadUI = require("spec/support/load_ui")
local STATUS = require("storygraph/lib/constants/hardcover").STATUS
local SETTING = require("storygraph/lib/constants/settings")
local function find(items, text)
  for _, item in ipairs(items) do
    local label = item.text_func and item.text_func() or item.text
    if label and label:find(text,1,true) then return item end
  end
end

describe("Redesigned StoryGraph menus", function()
  local menu, values, linked, tracking, events, shown, refreshes, notes, updated, linked_search, edition_search
  before_each(function()
    values,events,shown,notes,updated={}, {}, {}, {}, {}
    linked,tracking,refreshes=true,true,0
    local widget={new=function(_, options) return options end}
    local Menu=loadUI("storygraph/lib/ui/hardcover_menu.lua",{
      ["ui/uimanager"]={show=function(_,o) shown[#shown+1]=o end,
        broadcastEvent=function(_,o) events[#events+1]=o end},
      ["ui/event"]={new=function(_,name) return name end},
      ["ui/widget/infomessage"]=widget,["ui/widget/spinwidget"]=widget,
      ["storygraph/lib/ui/action_menu"]=widget,["storygraph/lib/ui/home_dialog"]=widget,
      device={hasWifiRestore=function() return true end},
    })
    menu=Menu:new {enabled=true, ui={document={file="book.epub",getPageCount=function() return 100 end},
      getCurrentPage=function() return 42 end},state={book_status={status_id=STATUS.READING,last_reached_percent=37}},
      settings={bookLinked=function() return linked end, getLinkedTitle=function() return "Book" end,
        getLinkedBookId=function() return "id" end, getLinkedEditionId=function() return "edition" end,
        getLinkedEditionFormat=function() return "Paperback" end,syncEnabled=function() return tracking end,
        setSync=function(_,value) tracking=value end,readSetting=function(_,key) return values[key] end,
        readBookSetting=function(_,file,key) return values[key] end,
        updateSetting=function(_,key,value) values[key]=value end,menuConfirm=function() return true end,
        setMenuConfirm=function() end,compatibilityMode=function() return false end,
        pages=function() return 200 end,syncByRemotePages=function() return values.pages==true end,
        updateBookSetting=function(_,file,data) updated={file=file,data=data};linked=false end},
      app={sync_queue={count=function() return 3 end}},
      cache={cacheUserBook=function() refreshes=refreshes+1 end,
        updateBookStatus=function(_,file,status) menu.state.book_status.status_id=status;updated={file=file,status=status} end},
      dialog_manager={journalEntryForm=function(_,...) notes={...} end,
        maybeConfirm=function(_,options) shown[#shown+1]=options end},
      hardcover={showLinkBookDialog=function(_,force,done) linked_search=force;done() end,
        showChangeEditionDialog=function(_,done) edition_search=true;done() end},
      page_mapper={getMappedPage=function(_,page,total,remote) return page/total*remote end}}
    linked_search,edition_search=nil,nil
  end)

  it("shows the last confirmed percentage and local date/time in the book card",function()
    local summary=menu:getSubMenuItems(true)[1]
    assert.matches("Last progress sync: Not yet recorded",summary.sync_text_func(),1,true)
    values.last_progress_sync={book_id="id",percent=42.5,at=1791711000}
    assert.matches("Last synced progress: 42.5%",summary.sync_text_func(),1,true)
    assert.matches("Synced on: "..os.date("%d/%m/%Y %H:%M",1791711000),summary.sync_text_func(),1,true)
    assert.is_nil(summary.text_func():find("Last synced progress",1,true))
    values.last_progress_sync.book_id="old-edition"
    assert.matches("Last progress sync: Not yet recorded",summary.sync_text_func(),1,true)
    linked=false
    assert.is_nil(summary.sync_text_func())
  end)

  it("opens the standalone menu through the callback used by new ZenOS shortcuts",function()
    menu:mainMenu().callback({closeMenu=function() end})
    assert.are.equal(1,#shown)
    assert.are.equal("StoryGraph",shown[1].title)
    assert.is_not_nil(shown[1].items_func)
    assert.is_function(shown[1].onLeftButtonTap)
  end)

  it("separates configuration from reading without dropping moved actions",function()
    local main=menu:getSubMenuItems(true)
    for _, label in ipairs({"Link book","Linked book:","Change edition","Automatically track progress","Settings","About"}) do
      assert.is_nil(find(main,label))
    end
    for _, label in ipairs({"Progress and notes","Status and review","Jump to StoryGraph position","Pending synchronization"}) do
      assert.is_not_nil(find(main,label))
    end
    local settings=menu:getSettingsSubMenuItems()
    for _, label in ipairs({"Linked book:","Change edition","Automatically track progress","About",
      "Automatically link by ISBN","Automatically link by StoryGraph identifier","Automatically link by title and author",
      "Progress tracking settings","Enable Wi-Fi on demand","Confirm changes to reading status",
      "Compatibility mode","Include location info in regular notes","Account (cookies and tokens)","Plugin updates"}) do
      assert.is_not_nil(find(settings,label))
    end
  end)

  it("keeps settings and the queue accessible without an active document",function()
    menu.ui.document=nil
    local main=menu:getSubMenuItems(false)
    assert.is_not_nil(find(main,"Pending synchronization"))
    assert.is_nil(find(main,"Progress and notes"))
    local settings=menu:getSettingsSubMenuItems()
    assert.is_nil(find(settings,"Change edition"))
    assert.is_not_nil(find(settings,"Account (cookies and tokens)"))
    menu:showMenu(); shown[1].onLeftButtonTap(shown[1])
    assert.are.equal("StoryGraph settings",shown[2].title)
  end)

  it("preserves availability of progress for every reading state",function()
    for _,status in ipairs({STATUS.TO_READ,STATUS.READING,STATUS.FINISHED,STATUS.PAUSED,STATUS.DNF}) do
      menu.state.book_status.status_id=status
      assert.are.equal(status==STATUS.READING or status==STATUS.PAUSED,menu:getProgressMenuItem().enabled_func())
    end
    menu.state.book_status={};assert.is_true(menu:getProgressMenuItem().enabled_func())
    linked=false;assert.is_false(menu:getProgressMenuItem().enabled_func())
    linked=true;menu.enabled=false;assert.is_false(menu:getProgressMenuItem().enabled_func())
    values[SETTING.IGNORE_VERSION_BLOCK]=true;assert.is_true(menu:getProgressMenuItem().enabled_func())
  end)

  it("refreshes before opening progress and retains its original journal arguments",function()
    menu:getProgressMenuItem().callback()
    assert.are.equal(1,refreshes)
    assert.are.same({"",menu.ui.document,42,200,nil,37,"note"},notes)
    menu.cache.cacheUserBook=function() menu.state.book_status.status_id=STATUS.FINISHED end
    notes={};menu:getProgressMenuItem().callback();assert.are.same({},notes)
    values.pages=true;assert.matches("84 / 200",menu:getProgressMenuItem().text_func(),1,true)
  end)

  it("preserves linking, edition switching, tracking and long-press unlink",function()
    local settings=menu:getSettingsSubMenuItems()
    local instance={updateItems=function() end}
    find(settings,"Linked book:").callback(instance);assert.is_true(linked_search)
    find(settings,"Change edition").callback(instance);assert.is_true(edition_search)
    find(settings,"Automatically track progress").callback();assert.is_false(tracking)
    find(settings,"Linked book:").hold_callback(instance)
    assert.are.equal("book.epub",updated.file)
    assert.are.same({'book_id','edition_id','edition_format','pages','title'},updated.data._delete)
    assert.is_not_nil(find(menu:getSettingsSubMenuItems(),"Link book"))
  end)

  it("retains all status choices and their confirmations",function()
    local items=menu:getStatusSubMenuItems()
    assert.are.equal(8,#items)
    for _,status in ipairs({STATUS.TO_READ,STATUS.READING,STATUS.FINISHED,STATUS.PAUSED,STATUS.DNF}) do
      items[status].callback({updateItems=function() end})
      assert.is_not_nil(shown[#shown].ok_callback)
      shown[#shown].ok_callback()
      assert.are.equal(status,updated.status)
    end
    assert.is_not_nil(find(items,"Owned"));assert.is_not_nil(find(items,"Favorite"))
    assert.is_not_nil(find(items,"Remove"))
  end)

  it("keeps review availability conditional on the original states",function()
    for _,status in ipairs({STATUS.TO_READ,STATUS.READING,STATUS.FINISHED,STATUS.PAUSED,STATUS.DNF}) do
      menu.state.book_status.status_id=status
      assert.are.equal(status==STATUS.FINISHED or status==STATUS.DNF,find(menu:getStatusSubMenuItems(),"Review")~=nil)
    end
    menu.state.book_status={status_id=STATUS.READING,can_review=true}
    assert.is_not_nil(find(menu:getStatusSubMenuItems(),"Review"))
    local items=menu:getReviewSubMenuItems()
    for _,label in ipairs({"Rating:","Moods","Pace:","Driven by:","Character development:","Loveable characters:",
      "Diverse cast:","Character flaws:","Themes","Thoughts","Save review","Cancel review"}) do
      assert.is_not_nil(find(items,label))
    end
  end)

  it("retains the jump event and nested account/update/tracking options",function()
    find(menu:getSubMenuItems(true),"Jump to StoryGraph position").callback()
    assert.are.same({"StoryGraphPullPosition"},events)
    assert.are.equal(2,#menu:getAuthSubMenuItems())
    assert.are.equal(3,#menu:getUpdateSubMenuItems())
    assert.are.equal(8,#menu:getTrackingSubMenuItems())
  end)
end)
