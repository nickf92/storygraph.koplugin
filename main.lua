local _ = require("gettext")
local DataStorage = require("datastorage")

-- Migration: Rename hardcover_config.lua to storygraph_config.lua if it exists
local plugin_dir = DataStorage:getDataDir() .. "/plugins/storygraph.koplugin"
local old_config = plugin_dir .. "/hardcover_config.lua"
local new_config = plugin_dir .. "/storygraph_config.lua"

local f_new = io.open(new_config, "r")
if not f_new then
    local f_old = io.open(old_config, "r")
    if f_old then
        f_old:close()
        os.rename(old_config, new_config)
    end
else
    f_new:close()
end

local Dispatcher = require("dispatcher")
local DocSettings = require("docsettings")
local logger = require("logger")
local LuaSettings = require("luasettings")
local math = require("math")

local NetworkManager = require("ui/network/manager")
local Trapper = require("ui/trapper")
local UIManager = require("ui/uimanager")
local Event = require("ui/event")

local InfoMessage = require("ui/widget/infomessage")
local Notification = require("ui/widget/notification")

local WidgetContainer = require("ui/widget/container/widgetcontainer")

local _t = require("storygraph/lib/table_util")
local Api = require("storygraph/lib/hardcover_api")
local AutoWifi = require("storygraph/lib/auto_wifi")
local BackgroundSync = require("storygraph/lib/background_sync")
local Cache = require("storygraph/lib/cache")
local debounce = require("storygraph/lib/debounce")
local Hardcover = require("storygraph/lib/hardcover")
local HardcoverSettings = require("storygraph/lib/hardcover_settings")
local PageMapper = require("storygraph/lib/page_mapper")
local Scheduler = require("storygraph/lib/scheduler")
local SyncDispatcher = require("storygraph/lib/sync_dispatcher")
local SyncQueue = require("storygraph/lib/sync_queue")
local SyncSender = require("storygraph/lib/sync_sender")
local throttle = require("storygraph/lib/throttle")
local User = require("storygraph/lib/user")
local VersionCheck = require("storygraph/lib/version_check")

local DialogManager = require("storygraph/lib/ui/dialog_manager")
local HardcoverMenu = require("storygraph/lib/ui/hardcover_menu")

local HARDCOVER = require("storygraph/lib/constants/hardcover")
local SETTING = require("storygraph/lib/constants/settings")

local HardcoverApp = WidgetContainer:extend {
  name = "storygraph",
  is_doc_only = false,
  state = nil,
  settings = nil,
  width = nil,
  enabled = true
}

local HIGHLIGHT_MENU_NAME = "13_0_make_storygraph_highlight_item"

function HardcoverApp:onDispatcherRegisterActions()
  Dispatcher:registerAction("storygraph_link", {
    category = "none",
    event = "StoryGraphLink",
    title = _("StoryGraph: Link book"),
    general = true,
  })

  Dispatcher:registerAction("storygraph_track", {
    category = "none",
    event = "StoryGraphTrack",
    title = _("StoryGraph: Track progress"),
    general = true,
  })

  Dispatcher:registerAction("storygraph_stop_track", {
    category = "none",
    event = "StoryGraphStopTrack",
    title = _("StoryGraph: Stop tracking progress"),
    general = true,
  })

  Dispatcher:registerAction("storygraph_update_progress", {
    category = "none",
    event = "StoryGraphUpdateProgress",
    title = _("StoryGraph: Update progress"),
    general = true,
  })


end

function HardcoverApp:init()
  self.state = {
    page = nil,
    pos = nil,
    search_results = {},
    book_status = {},
    page_update_pending = false,
    progress_dirty = false
  }
  --logger.warn("HARDCOVER app init")
  self.settings = HardcoverSettings:new(
    ("%s/%s"):format(DataStorage:getSettingsDir(), "storygraphsync_settings.lua"),
    self.ui
  )
  self.settings:subscribe(function(field, change, original_value) self:onSettingsChanged(field, change, original_value) end)

  User.settings = self.settings
  Api.settings = self.settings
  Api.on_error = function(err)
    if not err or not self.enabled then
      return
    end

    if err == "Unauthorized" or (err.message and string.find(err.message, "login")) then
      self:disable()
      UIManager:show(InfoMessage:new {
        text = "Your StoryGraph session cookie is not valid or has expired. Please update it.",
        icon = "notice-warning",
      })
    end
  end

  self.sync_queue = SyncQueue:new {
    storage = LuaSettings:open(
      ("%s/%s"):format(DataStorage:getSettingsDir(), "storygraphsync_queue.lua")
    ),
  }
  self._documentSessionCounter = 0
  self._documentSessionPrefix = tostring({})
  self._syncQueueCallbacks = {}
  self.sync_sender = SyncSender:new { api = Api }
  self.sync_dispatcher = SyncDispatcher:new {
    queue = self.sync_queue,
    is_connected = function()
      return not self._networkDisconnecting and NetworkManager:isConnected()
    end,
    send = function(operation)
      return self.sync_sender:send(operation)
    end,
    on_success = function(operation, result)
      self:_onQueuedOperationSuccess(operation, result)
    end,
    on_failure = function(operation, reason)
      self:_onQueuedOperationFailure(operation, reason)
    end,
  }

  self.cache = Cache:new {
    settings = self.settings,
    state = self.state,
    ui = self.ui,
    enqueue_operation = function(operation)
      return self:_enqueueSyncOperation(operation)
    end,
  }
  self.page_mapper = PageMapper:new {
    state = self.state,
    ui = self.ui,
  }
  self.wifi = AutoWifi:new {
    settings = self.settings
  }
  self.background_sync = BackgroundSync:new {
    wifi = self.wifi,
    is_connected = function()
      return not self._networkDisconnecting and NetworkManager:isConnected()
    end,
    wifi_enabled = function()
      return self.settings:readSetting(SETTING.ENABLE_WIFI) == true
    end,
    cooldown_seconds = function()
      return math.max(math.min(self.settings:trackFrequency(), 120), 1) * 60
    end,
    can_attempt = function()
      if self._syncQueueFlushJob then return false, "flush_scheduled" end
      if self.sync_dispatcher.busy then return false, "dispatcher_busy" end
      if self._syncQueueRetryBlocked then return false, "retry_blocked" end
      if self._networkDisconnecting then return false, "network_disconnecting" end
      return true
    end,
    request_flush = function()
      return self:_requestSyncQueueFlush()
    end,
    drain_now = function()
      if self._syncQueueFlushJob then
        UIManager:unschedule(self._syncQueueFlushJob)
        self._syncQueueFlushJob = nil
      end
      local queued_before = self.sync_queue:count()
      local success, status = self:_drainSyncQueueNow()
      logger.info(("StoryGraph: background queue drain finished; status=%s, pending_before=%d, pending_after=%d")
        :format(tostring(status), queued_before, self.sync_queue:count()))
      return success, status
    end,
    on_status = function(status, details)
      local pending = self.sync_queue:count()
      local consumer = details.consumer or "background_sync"
      if status == "trying_wifi" then
        logger.info(("StoryGraph: automatic wifi attempt started; consumer=%s, pending=%d, cooldown=%ds")
          :format(consumer, pending, details.cooldown_seconds))
      elseif status == "wifi_connected" then
        logger.info(("StoryGraph: automatic wifi connected; consumer=%s, pending=%d")
          :format(consumer, pending))
      elseif status == "wifi_unavailable" then
        logger.info(("StoryGraph: automatic wifi unavailable; consumer=%s, pending=%d, next_attempt_in=%ds")
          :format(consumer, pending, details.cooldown_seconds))
      elseif status == "already_in_progress" then
        logger.dbg(("StoryGraph: automatic wifi attempt already covers consumer=%s"):format(consumer))
      elseif status == "joined_in_progress" then
        logger.dbg(("StoryGraph: automatic wifi consumer joined active attempt; consumer=%s"):format(consumer))
      elseif status == "connected_during_wifi_attempt" then
        logger.dbg("StoryGraph: NetworkConnected handled by shared automatic wifi attempt")
      elseif status == "cooldown" then
        logger.dbg(("StoryGraph: automatic wifi cooldown active; consumer=%s, remaining=%ds, pending=%d")
          :format(consumer, math.ceil(details.remaining_seconds), pending))
      elseif status == "blocked" then
        logger.dbg(("StoryGraph: automatic wifi attempt skipped; consumer=%s, reason=%s, pending=%d")
          :format(consumer, details.reason, pending))
      elseif status == "wifi_disabled" then
        logger.dbg(("StoryGraph: automatic wifi attempt skipped; consumer=%s, reason=disabled, pending=%d")
          :format(consumer, pending))
      elseif status == "wifi_not_started" then
        logger.info(("StoryGraph: automatic wifi could not start; consumer=%s, reason=%s, pending=%d")
          :format(consumer, details.reason, pending))
      end
    end,
  }
  self.version_check = VersionCheck:new {
    automatic_wifi = self.background_sync,
    manual_wifi = self.wifi,
    is_connected = function()
      return NetworkManager:isConnected()
    end,
    fetch = function()
      local Github = require("storygraph/lib/github")
      return Github:fetchVersionInfo()
    end,
    read_last_check = function()
      return self.settings:readSetting(SETTING.LAST_VERSION_CHECK)
    end,
    read_interval_days = function()
      return self.settings:readSetting(SETTING.VERSION_CHECK_INTERVAL) or 1
    end,
    write_last_check = function(timestamp)
      self.settings:updateSetting(SETTING.LAST_VERSION_CHECK, timestamp)
    end,
    schedule_in = function(delay, job)
      UIManager:scheduleIn(delay, job)
    end,
    unschedule = function(job)
      UIManager:unschedule(job)
    end,
    can_check = function()
      return self.enabled or self.settings:readSetting(SETTING.IGNORE_VERSION_BLOCK) == true
    end,
    on_success = function(info)
      return self:_handleVersionInfo(info)
    end,
    on_status = function(status, details)
      if status == "not_due" then
        logger.dbg(("StoryGraph: version check not due; next_check_in=%ds")
          :format(math.ceil(details.remaining_seconds)))
      elseif status == "due" then
        logger.dbg("StoryGraph: version check due")
      elseif status == "offline" then
        logger.info("StoryGraph: version check offline; last successful check unchanged")
      elseif status == "fetch_failed" then
        logger.info("StoryGraph: version check fetch failed; last successful check unchanged")
      elseif status == "succeeded" then
        logger.info("StoryGraph: version check succeeded")
      elseif status == "skipped" then
        logger.dbg(("StoryGraph: version check skipped; reason=%s"):format(details.reason or "unknown"))
      end
    end,
  }
  self.dialog_manager = DialogManager:new {
    page_mapper = self.page_mapper,
    settings = self.settings,
    state = self.state,
    ui = self.ui,
    wifi = self.wifi,
    enqueue_operation = function(operation)
      return self:_enqueueSyncOperation(operation)
    end,
  }
  self.hardcover = Hardcover:new {
    automatic_wifi = self.background_sync,
    cache = self.cache,
    dialog_manager = self.dialog_manager,
    settings = self.settings,
    state = self.state,
    ui = self.ui,
    wifi = self.wifi
  }

  self.menu = HardcoverMenu:new {
    app = self,
    enabled = true,

    cache = self.cache,
    dialog_manager = self.dialog_manager,
    hardcover = self.hardcover,
    page_mapper = self.page_mapper,
    settings = self.settings,
    state = self.state,
    ui = self.ui,
  }

  self:onDispatcherRegisterActions()
  self:initializePageUpdate()
  self.ui.menu:registerToMainMenu(self)
  self:_requestSyncQueueFlush()
end

function HardcoverApp:_bookSettingChanged(setting, key)
  return setting[key] ~= nil or _t.contains(_t.dig(setting, "_delete"), key)
end

-- Open note dialog
--
-- UIManager:broadcastEvent(Event:new("HardcoverNote", note_params))
--
-- note_params can contain:
--   text: Value will prepopulate the note section
--   page_number: The local page number
--   remote_page (optional): The mapped page in the linked book edition
--   note_type: one of "quote" or "note"
function HardcoverApp:onStoryGraphNote(note_params)
  if not self:isActive() then return end
  local remote_percent = self.state.book_status.last_reached_percent or 0
  self.dialog_manager:journalEntryForm(
    note_params.text,
    self.ui.document,
    note_params.page_number,
    self.settings:pages(),
    note_params.remote_page or nil,
    remote_percent,
    note_params.note_type or "quote"
  )
end

function HardcoverApp:disable()
  self.enabled = false
  if self.menu then
    self.menu.enabled = false
  end
  self:registerHighlight()
end

function HardcoverApp:onStoryGraphLink()
  self.hardcover:showLinkBookDialog(false, function(book)
    UIManager:show(Notification:new {
      text = _("Linked to: " .. book.title),
    })
  end)
end

function HardcoverApp:onStoryGraphTrack()
  self.settings:setSync(true)
  UIManager:nextTick(function()
    UIManager:show(Notification:new {
      text = _("Progress tracking enabled")
    })
  end)
end

function HardcoverApp:onStoryGraphStopTrack()
  self.settings:setSync(false)
  UIManager:show(Notification:new {
    text = _("Progress tracking disabled")
  })
end

function HardcoverApp:onStoryGraphPullPosition()
  if not self.ui.document or not self.settings:bookLinked() then return end

  local ConfirmBox = require("ui/widget/confirmbox")
  local book_id = self.settings:getLinkedBookId()

  UIManager:show(Notification:new {
    text = _("Fetching position from StoryGraph..."),
    timeout = 3,
  })

  self.wifi:withWifi(function()
    local status = Api:findUserBook(book_id, User:getId())
    if not status or not status.last_reached_percent then
      UIManager:show(InfoMessage:new {
        text = _("Could not fetch position from StoryGraph."),
        icon = "notice-warning",
      })
      return
    end

    local remote_percent = tonumber(status.last_reached_percent) or 0
    if remote_percent == 0 then
      UIManager:show(InfoMessage:new {
        text = _("StoryGraph shows no progress recorded yet."),
      })
      return
    end

    local document_pages = self.ui.document:getPageCount()
    local target_page = math.max(1, math.floor((remote_percent / 100) * document_pages))

    UIManager:show(ConfirmBox:new {
      text = _(string.format(
        "StoryGraph shows %d%% progress.\nJump to page %d of %d?",
        remote_percent, target_page, document_pages
      )),
      ok_text = _("Jump"),
      ok_callback = function()
        self.ui:handleEvent(Event:new("GotoPage", target_page))
        -- Update cached status
        self.state.book_status = status
      end,
    })
  end)
end

function HardcoverApp:onStoryGraphUpdateProgress()
  if self.ui.document and self.settings:bookLinked() then
    self:updatePageNow(function(result, status)
      if result then
        UIManager:show(Notification:new {
          text = _("Progress updated")
        })
      elseif status == "queued" then
        UIManager:show(Notification:new {
          text = _("Progress saved for synchronization")
        })
      else
        logger.warn("Unsuccessful updating page progress", self.ui.document.file)
      end
    end)
  else
    logger.warn(self.state.book_status)
    local error
    if not self.ui.document then
      error = "No book active"
    elseif not self.state.book_status.id then
      error = "Book has not been mapped"
    end

    local error_message = error and "Unable to update reading progress: " .. error or "Unable to update reading progress"
    UIManager:show(InfoMessage:new {
      text = error_message,
      icon = "notice-warning",
    })
  end
end

function HardcoverApp:_notifySyncQueueError(err)
  if err == "queue_full" then
    if self._syncQueueFullNotified then
      return
    end
    self._syncQueueFullNotified = true
    UIManager:show(Notification:new {
      text = _("StoryGraph queue is full; an update was not saved"),
    })
    return
  end

  UIManager:show(InfoMessage:new {
    text = _("Unable to save a StoryGraph update locally"),
    icon = "notice-warning",
  })
end

function HardcoverApp:_enqueueSyncOperation(operation, callback, options)
  options = options or {}
  local notify_error = operation.notify_error ~= false
  operation.notify_error = nil
  operation.session_id = operation.session_id or self._documentSessionId

  local queued, err, replaced_id = self.sync_queue:enqueue(operation)
  if not queued then
    logger.warn("StoryGraph: Unable to enqueue operation", operation.kind, err)
    if notify_error then
      self:_notifySyncQueueError(err)
    end
    return nil, err
  end

  if replaced_id then
    self._syncQueueCallbacks[replaced_id] = nil
  end

  if operation.priority == "before_progress" then
    self._syncQueueRetryBlocked = false
  end

  if callback then
    if self.sync_queue:count() == 1 and not self.sync_dispatcher.busy
        and NetworkManager:isConnected() and not self._networkDisconnecting then
      self._syncQueueCallbacks[queued.id] = callback
    else
      callback(nil, "queued")
    end
  end

  self.page_update_pending = self.ui.document
    and self.sync_queue:hasPending(self.ui.document.file, "progress")
    or false
  if options.background_sync then
    self.background_sync:request()
  else
    self:_requestSyncQueueFlush()
  end
  return queued
end

function HardcoverApp:_onQueuedOperationSuccess(operation, result)
  local callback = self._syncQueueCallbacks[operation.id]
  self._syncQueueCallbacks[operation.id] = nil

  if self.ui.document and self.ui.document.file == operation.document
      and operation.session_id == self._documentSessionId then
    if type(result) == "table" and result.id then
      self.state.book_status = result
    elseif type(result) == "table" and result._storygraph_skipped then
      if result.last_reached_percent then
        self.state.book_status.last_reached_percent = result.last_reached_percent
        self.state.book_status.percent_finished = result.last_reached_percent
      end
      if result.last_reached_pages then
        self.state.book_status.last_reached_pages = result.last_reached_pages
      end
    end
    if operation.kind == "progress" then
      local payload = operation.payload
      if self.state.latest_page == payload.local_page then
        self.state.progress_dirty = false
      end
      self.page_update_pending = self.sync_queue:hasPending(operation.document, "progress")
    end
    self:registerHighlight()
  end

  if callback and operation.session_id == self._documentSessionId then
    callback(result)
  end
end

function HardcoverApp:_startDocumentSession()
  self._documentSessionCounter = self._documentSessionCounter + 1
  self._documentSessionId = self._documentSessionPrefix .. ":" .. self._documentSessionCounter
end

function HardcoverApp:_onQueuedOperationFailure(operation, reason)
  local callback = self._syncQueueCallbacks[operation.id]
  self._syncQueueCallbacks[operation.id] = nil
  if reason ~= "superseded" then
    self._syncQueueRetryBlocked = true
    logger.warn("StoryGraph: Queued operation failed", operation.kind, reason)
    if reason == "not_reading" then
      UIManager:show(Notification:new {
        text = _("StoryGraph progress is pending. Mark this book as Currently Reading to synchronize it."),
      })
    elseif reason == "progress_unconfirmed" then
      UIManager:show(Notification:new {
        text = _("StoryGraph did not confirm the progress update. It remains queued."),
      })
    end
  else
    logger.info("StoryGraph: Queued progress superseded by a newer value")
  end
  if callback and operation.session_id == self._documentSessionId then
    callback(nil, reason == "superseded" and "queued" or reason)
  end
end

function HardcoverApp:_drainSyncQueueNow()
  if self._syncQueueRetryBlocked then
    return false, "retry_blocked"
  end
  while NetworkManager:isConnected() and not self._networkDisconnecting
      and not self._syncQueueRetryBlocked do
    local success, status = self.sync_dispatcher:drainOne()
    if not success or status == "empty" then
      return success, status
    end
  end
  return false, "offline"
end

function HardcoverApp:_requestSyncQueueFlush()
  if self._syncQueueFlushJob or self.sync_dispatcher.busy
      or self._syncQueueRetryBlocked or self._networkDisconnecting
      or not NetworkManager:isConnected() then
    return false
  end

  local job
  job = function()
    if self._syncQueueFlushJob ~= job then
      return
    end
    self._syncQueueFlushJob = nil
    Trapper:wrap(function()
      self:_drainSyncQueueNow()
    end)
  end
  self._syncQueueFlushJob = job
  UIManager:nextTick(job)
  return true
end

function HardcoverApp:onSettingsChanged(field, change, original_value)
  if field == SETTING.BOOKS then
    local book_settings = change.config
    if self:_bookSettingChanged(book_settings, "sync") then
      if book_settings.sync then
        self.state.process_page_turns = true
        if not self.state.book_status.id then
          self:startReadCache(true)
        end
      else
        self.state.process_page_turns = false
        self:cancelPendingUpdates(true)
      end
    end

    if self:_bookSettingChanged(book_settings, "book_id") then
      self:registerHighlight()
    end
  elseif field == SETTING.TRACK_METHOD then
    self:cancelPendingUpdates()
    self:initializePageUpdate()
  elseif field == SETTING.LINK_BY_ISBN or field == SETTING.LINK_BY_STORYGRAPH or field == SETTING.LINK_BY_TITLE then
    if change then
      self.hardcover:tryAutolink(true)
    end
  elseif field == SETTING.SESSION_COOKIE or field == SETTING.REMEMBER_TOKEN then
    self._syncQueueRetryBlocked = false
    self:_requestSyncQueueFlush()
  elseif field == SETTING.VERSION_CHECK_INTERVAL then
    self.version_check:schedule(1, true)
  end
end

function HardcoverApp:_handlePageUpdate(filename, value, immediate, callback, update_type)
  update_type = update_type or "percentage"

  if not self:syncFileUpdates(filename) then
    if callback then callback(nil, "sync_disabled") end
    return
  end

  local status_id = self.state.book_status.status_id
  if status_id and status_id ~= HARDCOVER.STATUS.READING then
    if callback then callback(nil, "not_reading") end
    return
  end

  if update_type == "percentage" then
    local remote_percent = tonumber(self.state.book_status.percent_finished) or 0
    if not immediate and value < remote_percent then
      logger.info("StoryGraph: Local progress (" .. value .. "%) is behind remote (" .. remote_percent .. "%). Skipping auto-update.")
      if callback then callback(nil, "behind_remote") end
      return
    end
  elseif update_type == "pages" then
    local remote_page = tonumber(self.state.book_status.last_reached_pages) or 0
    if not immediate and value < remote_page then
      logger.info("StoryGraph: Local progress (" .. value .. " pages) is behind remote (" .. remote_page .. " pages). Skipping auto-update.")
      if callback then callback(nil, "behind_remote") end
      return
    end
  end

  local reads = self.state.book_status.user_book_reads
  local current_read = reads and reads[#reads]
  local book_id = self.settings:readBookSetting(filename, "book_id")
    or self.settings:readBookSetting(filename, "edition_id")
  if not book_id then
    if callback then callback(nil, "book_not_linked") end
    return
  end

  return self:_enqueueSyncOperation({
    document = filename,
    book_id = book_id,
    kind = "progress",
    payload = {
      value = value,
      update_type = update_type,
      started_at = current_read and current_read.started_at,
      local_page = self.state.latest_page or self.state.page,
      allow_regression = immediate == true,
    },
  }, callback, {
    background_sync = immediate ~= true,
  })
end

function HardcoverApp:initializePageUpdate()
  local track_frequency = math.max(math.min(self.settings:trackFrequency(), 120), 1) * 60

  HardcoverApp._throttledHandlePageUpdate, HardcoverApp._cancelPageUpdate = throttle(
    track_frequency,
    HardcoverApp._handlePageUpdate
  )

  HardcoverApp.onPageUpdate, HardcoverApp._cancelPageUpdateEvent = debounce(2, HardcoverApp.pageUpdateEvent)
end

function HardcoverApp:pageUpdateEvent(page)
  self.state.last_page = self.state.page
  self.state.page = page

  if not self.ui.document or not self:syncFileUpdates(self.ui.document.file) then
    return
  end
  --logger.warn("HARDCOVER page update event pending")
  local document_pages = self.ui.document:getPageCount()
  local remote_pages = self.settings:pages()

  if self.settings:trackByTime() then
    local decimal_percent, mapped_page = self.page_mapper:getRemotePagePercent(
      self.state.page,
      self.ui.document:getPageCount(),
      self.settings:pages()
    )
    local value, update_type
    if self.settings:syncByRemotePages() and tonumber(remote_pages) and tonumber(remote_pages) > 0 and mapped_page then
      value = mapped_page
      update_type = "pages"
    else
      value = math.floor(decimal_percent * 100 + 0.5)
      update_type = "percentage"
    end

    self.page_update_pending = true
    self:_throttledHandlePageUpdate(self.ui.document.file, value, false, nil, update_type)
  elseif (self.settings:trackByProgress() or self.settings:trackByPages()) and self.state.last_page then
    local previous_percent, previous_mapped_page = self.page_mapper:getRemotePagePercent(
      self.state.last_page,
      document_pages,
      remote_pages
    )

    local current_percent, current_mapped_page = self.page_mapper:getRemotePagePercent(
      self.state.page,
      document_pages,
      remote_pages
    )

    local should_sync = false
    if self.settings:trackByProgress() then
      local percent_interval = self.settings:trackPercentageInterval()
      local last_compare = math.floor(previous_percent * 100 / percent_interval)
      local current_compare = math.floor(current_percent * 100 / percent_interval)
      should_sync = (last_compare ~= current_compare)
    elseif self.settings:trackByPages() then
      local page_step = self.settings:trackPageStep()
      local last_compare = math.floor(previous_mapped_page / page_step)
      local current_compare = math.floor(current_mapped_page / page_step)
      should_sync = (last_compare ~= current_compare)
    end

    if should_sync then
      local percentage = math.floor(current_percent * 100 + 0.5)
      local last_percent = math.floor(previous_percent * 100 + 0.5)
      local remote_percent = tonumber(self.state.book_status.percent_finished) or 0
      if percentage > last_percent and percentage >= remote_percent then
        if self.settings:syncByRemotePages() and tonumber(remote_pages) and tonumber(remote_pages) > 0 and current_mapped_page then
          self:_handlePageUpdate(self.ui.document.file, current_mapped_page, false, nil, "pages")
        else
          self:_handlePageUpdate(self.ui.document.file, percentage)
        end
      end
    end
  end
end

function HardcoverApp:onPosUpdate(_, page)
  self.state.latest_page = page
  if self.state.process_page_turns then
    self.state.progress_dirty = page ~= self.state.page
    self:pageUpdateEvent(page)
  end
end

function HardcoverApp:onUpdatePos()
  self.page_mapper:cachePageMap()
end

function HardcoverApp:onReaderReady()
  self:_startDocumentSession()
  self.page_mapper:cachePageMap()
  self:registerHighlight()
  self.state.page = self.ui:getCurrentPage()
  self.state.latest_page = self.state.page
  self.state.progress_dirty = false
  self.state.process_page_turns = self.settings:bookLinked() and self.settings:syncEnabled()
  self.page_update_pending = self.ui.document
    and self.sync_queue:hasPending(self.ui.document.file, "progress")
    or false
 
  if self.ui.document and (self.settings:bookLinked() or self.settings:autolinkEnabled()) then
    UIManager:scheduleIn(1, self.startReadCache, self)
  end
  self.version_check:schedule(1)
end

function HardcoverApp:initiateVersionCheck()
  return self.version_check:initiate()
end

function HardcoverApp:checkForUpdates(manual)
  return self.version_check:check(manual == true)
end

function HardcoverApp:_handleVersionInfo(info)
  local plugin_path = self.path or (DataStorage:getPluginDir() .. "/storygraph.koplugin")
  local Meta = dofile(plugin_path .. "/_meta.lua")

  if info.api_version and Meta.api_version < info.api_version then
    self.enabled = false
    self.menu.enabled = false

    if self.settings:readSetting(SETTING.IGNORE_VERSION_BLOCK) then
      UIManager:show(Notification:new {
        text = _("StoryGraph: Mandatory update available (Ignored)"),
        timeout = 5
      })
    else
      self:cancelPendingUpdates()

      if self.settings:readSetting(SETTING.SHOW_VERSION_DIALOG) ~= false then
        UIManager:show(Notification:new {
          text = info.message or _("StoryGraph: Mandatory update required!"),
          timeout = 10
        })
      end
    end
    return false
  end

  return true
end

function HardcoverApp:cancelPendingUpdates(discard_progress)
  local filename = self.ui.document and self.ui.document.file

  if self._cancelPageUpdate then
    self:_cancelPageUpdate()
  end

  if self._cancelPageUpdateEvent then
    self:_cancelPageUpdateEvent()
  end

  if self._endOfBookJob then
    UIManager:unschedule(self._endOfBookJob)
    self._endOfBookJob = nil
  end

  if discard_progress and filename then
    local removed_ids = {}
    for _, operation in ipairs(self.sync_queue:list()) do
      if operation.document == filename and operation.kind == "progress" then
        removed_ids[operation.id] = true
      end
    end
    local removed, err = self.sync_queue:removeWhere(function(operation)
      return operation.document == filename and operation.kind == "progress"
    end)
    if err then
      self:_notifySyncQueueError(err)
    elseif removed and removed > 0 then
      for operation_id in pairs(removed_ids) do
        self._syncQueueCallbacks[operation_id] = nil
      end
    end
  end
  self.page_update_pending = filename and self.sync_queue:hasPending(filename, "progress") or false
end

function HardcoverApp:onDocumentClose()
  UIManager:unschedule(self.startReadCache)

  local should_flush = self.state.progress_dirty or self.page_update_pending
  self:cancelPendingUpdates()
  Scheduler:clear()
  self.state.read_cache_started = false

  if should_flush and self.ui.document and self.settings:syncEnabled() then
    self:updatePageNow(nil, nil, nil, false)
  end

  self._documentSessionId = nil
  self.state.process_page_turns = false
  self.page_update_pending = false
  self.state.book_status = {}
  self.state.page_map = nil
end

function HardcoverApp:onSuspend()
  local should_flush = self.state.progress_dirty or self.page_update_pending
  self:cancelPendingUpdates()

  Scheduler:clear()
  self.state.read_cache_started = false

  if should_flush and self.ui.document and self.settings:syncEnabled() then
    self:updatePageNow(nil, nil, nil, false)
  end
  self._documentSessionId = nil
end

function HardcoverApp:onResume()
  if self.ui.document then
    self:_startDocumentSession()
  end
  self._syncQueueRetryBlocked = false
  self:_requestSyncQueueFlush()
  if self.ui.document and self.settings:syncEnabled()
      and (NetworkManager:isConnected() or self.settings:readSetting(SETTING.ENABLE_WIFI)) then
    UIManager:scheduleIn(2, self.startReadCache, self)
  end
end

function HardcoverApp:updatePageNow(callback, value, update_type, allow_regression)
  if not value then
    local page = self.state.latest_page or self.state.page
    local remote_pages = self.settings:pages()
    local decimal_percent, mapped_page = self.page_mapper:getRemotePagePercent(
      page,
      self.ui.document:getPageCount(),
      remote_pages
    )
    if self.settings:syncByRemotePages() and tonumber(remote_pages) and tonumber(remote_pages) > 0 and mapped_page then
      value = mapped_page
      update_type = "pages"
    else
      value = math.floor(decimal_percent * 100 + 0.5)
      update_type = "percentage"
    end
  end
  if allow_regression == nil then
    allow_regression = true
  end
  self:_handlePageUpdate(self.ui.document.file, value, allow_regression, callback, update_type)
end

function HardcoverApp:onNetworkDisconnecting()
  --logger.warn("HARDCOVER on disconnecting")
  self._networkDisconnecting = true

  local should_flush = self.state.progress_dirty or self.page_update_pending
  self:cancelPendingUpdates()

  Scheduler:clear()
  self.state.read_cache_started = false

  if should_flush and self.ui.document and self.settings:syncEnabled() then
    self:updatePageNow(nil, nil, nil, false)
  end
end

function HardcoverApp:onNetworkConnected()
  self._networkDisconnecting = false
  self._syncQueueRetryBlocked = false
  local pending = self.sync_queue:count()
  if pending > 0 and not self.background_sync:isWifiAttemptPending() then
    logger.info(("StoryGraph: network connected; requesting normal queue flush, pending=%d"):format(pending))
  end
  local _, flush_status = self.background_sync:onNetworkConnected()
  if flush_status == "automatic_wifi_attempt" then
    if self.ui.document and self.settings:syncEnabled() and not self.state.read_cache_started then
      self:startReadCache()
    end
    return
  end
  if self.ui.document and self.settings:syncEnabled() and not self.state.read_cache_started then
    --logger.warn("HARDCOVER on connected", self.state.read_cache_started)

    self:startReadCache()
  end
end

function HardcoverApp:onEndOfBook()
  local file_path = self.ui.document.file

  if not self:syncFileUpdates(file_path) then
    return
  end

  local mark_read = false
  if G_reader_settings:isTrue("end_document_auto_mark") then
    mark_read = true
  end

  if not mark_read then
    local action = G_reader_settings:readSetting("end_document_action") or "pop-up"
    mark_read = action == "mark_read"

    if action == "pop-up" then
      mark_read = 'later'
    end
  end

  if not mark_read then
    return
  end

  local marker = function()
    return self.cache:updateBookStatus(file_path, HARDCOVER.STATUS.FINISHED)
  end

  if mark_read == 'later' then
    local delayed_marker
    delayed_marker = function()
      self._endOfBookJob = nil
      local status = "reading"
      if DocSettings:hasSidecarFile(file_path) then
        local summary = DocSettings:open(file_path):readSetting("summary")
        if summary and summary.status and summary.status ~= "" then
          status = summary.status
        end
      end
      if status == "complete" then
        marker()
      end
    end
    self._endOfBookJob = delayed_marker
    UIManager:scheduleIn(30, delayed_marker)
  else
    if marker() then
      UIManager:show(InfoMessage:new {
        text = _("StoryGraph status saved for synchronization"),
        timeout = 2
      })
    end
  end
end

function HardcoverApp:syncFileUpdates(filename)
  return self.settings:readBookSetting(filename, "book_id") and self.settings:fileSyncEnabled(filename)
end

function HardcoverApp:onDocSettingsItemsChanged(file, doc_settings)
  if not self:syncFileUpdates(file) or not doc_settings then
    return
  end

  local status
  if doc_settings.summary.status == "complete" then
    status = HARDCOVER.STATUS.FINISHED
  elseif doc_settings.summary.status == "reading" then
    status = HARDCOVER.STATUS.READING
  end

  if status then
    if self.cache:updateBookStatus(file, status) then
      UIManager:show(InfoMessage:new {
        text = _("StoryGraph status saved for synchronization"),
        timeout = 2
      })
    end
  end
end

function HardcoverApp:startReadCache(manual_network)
  logger.info("StoryGraph: startReadCache triggered")
  if not self:isActive() then
    logger.info("StoryGraph: startReadCache aborted - app not active")
    return
  end

  if self.state.read_cache_started then
    logger.info("StoryGraph: startReadCache aborted - already started")
    return
  end

  if not self.ui.document then
    --logger.warn("HARDCOVER read cache fired outside of document")
    return
  end

  self.state.read_cache_started = true

  local cancel

  local restartAfterLink = function(delay)
    cancel()
    self.state.read_cache_started = false
    UIManager:scheduleIn(delay, self.startReadCache, self, manual_network)
  end

  cancel = Scheduler:withRetries(6, 3, function(success, fail)
      Trapper:wrap(function()
        if not self.ui.document then
          -- fail, but cancel retries
          return success()
        end
        local document = self.ui.document
        local filename = document.file
        local document_session_id = self._documentSessionId
        local book_settings = self.settings:readBookSettings(filename) or {}
        --logger.warn("HARDCOVER", book_settings)
        if book_settings.book_id then
          if self.state.book_status.id then
            return success()
          else
            local with_wifi = manual_network
              and function(callback)
                return self.wifi:withWifi(function(wifi_started)
                  callback(wifi_started, NetworkManager:isConnected())
                end)
              end
              or function(callback)
                return self.background_sync:withAutomaticWifi("read_cache", callback)
              end
            local accepted = with_wifi(function(_, connected)
              if connected ~= true or not NetworkManager:isConnected() then
                logger.info("StoryGraph: no network available; read cache remains pending")
                self.state.read_cache_started = false
                return success()
              end

              local current_document = self.ui.document
              if current_document ~= document
                  or current_document.file ~= filename
                  or self._documentSessionId ~= document_session_id then
                logger.info("StoryGraph: read cache cancelled - document context changed")
                self.state.read_cache_started = false
                return success()
              end

              if self._syncQueueFlushJob then
                UIManager:unschedule(self._syncQueueFlushJob)
                self._syncQueueFlushJob = nil
              end
              self:_drainSyncQueueNow()
              if not self:isActive() then
                return success()
              end

              local err = self.cache:cacheUserBook(filename)
              self:registerHighlight()
              logger.info("StoryGraph: startReadCache - cacheUserBook completed, status=" .. (self.state.book_status.status_id or "nil"))
              if err and err.completed == false then
                return fail(err)
              end

              success()
              self:registerHighlight() -- redundant but safe
            end)
            if not accepted then
              self.state.read_cache_started = false
              return success()
            end
          end
        else
          self.hardcover:tryAutolink()
          if self.settings:bookLinked() and self.settings:syncEnabled() then
            return restartAfterLink(2)
          end
        end
      end)
    end,

    function()
      if self.ui.document and self:isActive() and self.settings:syncEnabled() then
        --logger.warn("HARDCOVER enabling page turns")

        self.state.process_page_turns = true
      end
    end,

    function()
      if NetworkManager:isConnected() then
        UIManager:show(Notification:new {
          text = _("Failed to fetch book information from StoryGraph"),
        })
      end
    end)
end

function HardcoverApp:isActive()
  return self.enabled or self.settings:readSetting(SETTING.IGNORE_VERSION_BLOCK) == true
end

function HardcoverApp:registerHighlight()
  self.ui.highlight:removeFromHighlightDialog(HIGHLIGHT_MENU_NAME)

  if self.settings:bookLinked() then
    self.ui.highlight:addToHighlightDialog(HIGHLIGHT_MENU_NAME, function(this)
      return {
        text_func = function()
          return _("StoryGraph: Add note")
        end,
        enabled_func = function()
          local status = self.state.book_status.status_id
          return self:isActive() and (not status or (status ~= HARDCOVER.STATUS.FINISHED
            and status ~= HARDCOVER.STATUS.DNF and status ~= HARDCOVER.STATUS.TO_READ))
        end,
        callback = function()
          if not self:isActive() then return end
          local selected_text = this.selected_text
          local raw_page = selected_text.pos0.page
          if not raw_page then
            raw_page = self.view.document:getPageFromXPointer(selected_text.pos0)
          end
          -- open journal dialog
          self:onStoryGraphNote({
            text = selected_text.text,
            page_number = raw_page,
            note_type = "quote"
          })

          this:onClose()
        end,
      }
    end)
  end
end

function HardcoverApp:addToMainMenu(menu_items)
  menu_items.storygraph = self.menu:mainMenu()
end

return HardcoverApp
