local SyncQueue = {}
SyncQueue.__index = SyncQueue

local VERSION = 1
local DEFAULT_KEY = "sync_queue"
local DEFAULT_MAX_OPERATIONS = 100
local DEFAULT_MAX_OPERATIONS_PER_DOCUMENT = 25
local DEFAULT_MAX_BYTES = 64 * 1024

local VALID_KINDS = {
  note = true,
  progress = true,
  status = true,
}

local function clone(value, seen)
  if type(value) ~= "table" then
    return value
  end

  seen = seen or {}
  if seen[value] then
    return seen[value]
  end

  local copy = {}
  seen[value] = copy
  for key, item in pairs(value) do
    copy[clone(key, seen)] = clone(item, seen)
  end
  return copy
end

local function estimateSize(value, seen)
  local value_type = type(value)
  if value_type == "nil" then
    return 0
  elseif value_type == "boolean" then
    return 1
  elseif value_type == "number" then
    return 16
  elseif value_type == "string" then
    return #value
  elseif value_type ~= "table" then
    return #tostring(value)
  end

  seen = seen or {}
  if seen[value] then
    return 0
  end
  seen[value] = true

  local size = 8
  for key, item in pairs(value) do
    size = size + estimateSize(key, seen) + estimateSize(item, seen) + 2
  end
  return size
end

local function insertionIndex(operations, candidate)
  if candidate.kind == "status" and candidate.priority == "before_progress" then
    for index, queued in ipairs(operations) do
      if queued.document == candidate.document and queued.kind == "progress" then
        return index
      end
    end
  end
  return #operations + 1
end

local function normalizedState(value)
  if type(value) ~= "table" or value.version ~= VERSION or type(value.operations) ~= "table" then
    return {
      version = VERSION,
      next_id = 1,
      operations = {},
      paused_documents = {},
    }
  end

  local operations = {}
  local largest_id = 0
  local seen_ids = {}
  for _, operation in ipairs(value.operations) do
    if type(operation) == "table"
        and type(operation.id) == "number"
        and not seen_ids[operation.id]
        and VALID_KINDS[operation.kind]
        and type(operation.document) == "string"
        and operation.document ~= ""
        and operation.book_id ~= nil
        and type(operation.payload) == "table" then
      table.insert(operations, operation)
      seen_ids[operation.id] = true
      largest_id = math.max(largest_id, operation.id)
    end
  end

  return {
    version = VERSION,
    next_id = math.max(tonumber(value.next_id) or 1, largest_id + 1),
    operations = operations,
    paused_documents = type(value.paused_documents) == "table" and value.paused_documents or {},
  }
end

function SyncQueue:new(options)
  options = options or {}
  local queue = setmetatable({
    storage = options.storage,
    storage_key = options.storage_key or DEFAULT_KEY,
    max_operations = options.max_operations or DEFAULT_MAX_OPERATIONS,
    max_operations_per_document = options.max_operations_per_document
      or DEFAULT_MAX_OPERATIONS_PER_DOCUMENT,
    max_bytes = options.max_bytes or DEFAULT_MAX_BYTES,
    active = {},
  }, self)

  local stored
  if queue.storage and queue.storage.readSetting then
    local ok, value = pcall(queue.storage.readSetting, queue.storage, queue.storage_key)
    if ok then
      stored = value
    else
      queue.load_error = tostring(value)
    end
  end
  if type(stored) == "table" and stored.version ~= nil and stored.version ~= VERSION then
    queue.load_error = "unsupported queue version"
  end
  queue.state = normalizedState(stored)
  return queue
end

function SyncQueue:_persist()
  if self.load_error then
    return false, self.load_error
  end
  if not self.storage then
    return true
  end

  local ok, err = pcall(function()
    self.storage:saveSetting(self.storage_key, self.state)
    if self.storage.flush then
      self.storage:flush()
    end
  end)
  if not ok then
    return false, tostring(err)
  end
  return true
end

function SyncQueue:_mutate(callback)
  local previous = self.state
  self.state = clone(previous)
  local mutated, first, second, third = pcall(callback)
  if not mutated then
    self.state = previous
    return nil, "mutation_failed", tostring(first)
  end
  local persisted, err = self:_persist()
  if not persisted then
    self.state = previous
    if not self.load_error and self.storage and self.storage.saveSetting then
      pcall(self.storage.saveSetting, self.storage, self.storage_key, self.state)
    end
    return nil, "persist_failed", err
  end
  return first, second, third
end

function SyncQueue:enqueue(operation)
  if type(operation) ~= "table"
      or not VALID_KINDS[operation.kind]
      or type(operation.document) ~= "string"
      or operation.document == ""
      or operation.book_id == nil
      or type(operation.payload) ~= "table" then
    return nil, "invalid_operation"
  end

  local candidate = clone(operation)
  candidate.id = self.state.next_id
  candidate.book_id = tostring(candidate.book_id)
  candidate.created_at = candidate.created_at or os.time()

  if candidate.kind == "status" then
    for index = #self.state.operations, 1, -1 do
      local queued = self.state.operations[index]
      if queued.document == candidate.document then
        if queued.kind == "status"
            and queued.payload.status_id == candidate.payload.status_id then
          return clone(queued)
        end
        break
      end
    end
  end

  local replaced_index
  local replaced_id
  if candidate.kind == "progress" then
    for index = #self.state.operations, 1, -1 do
      local queued = self.state.operations[index]
      if queued.kind == "progress"
          and queued.document == candidate.document
          and not self.active[queued.id] then
        replaced_index = index
        replaced_id = queued.id
        break
      end
    end
  end

  local projected = clone(self.state)
  if replaced_index then
    table.remove(projected.operations, replaced_index)
  end
  table.insert(projected.operations, insertionIndex(projected.operations, candidate), candidate)
  projected.next_id = candidate.id + 1

  local document_operations = 0
  for _, queued in ipairs(projected.operations) do
    if queued.document == candidate.document then
      document_operations = document_operations + 1
    end
  end

  if #projected.operations > self.max_operations
      or document_operations > self.max_operations_per_document
      or estimateSize(projected) > self.max_bytes then
    return nil, "queue_full"
  end

  return self:_mutate(function()
    if replaced_index then
      table.remove(self.state.operations, replaced_index)
    end
    table.insert(self.state.operations, insertionIndex(self.state.operations, candidate), candidate)
    self.state.next_id = candidate.id + 1
    return candidate, nil, replaced_id
  end)
end

-- Retarget a document's pending operations in a single durable mutation. The
-- caller supplies the document/edition mapping; the queue owns ordering and IDs.
function SyncQueue:relinkDocument(document, book_id, remap)
  local ids = {}
  for _, operation in ipairs(self.state.operations) do
    if operation.document == document and operation.book_id ~= tostring(book_id) then
      if self.active[operation.id] then
        return nil, "operation_active"
      end
      ids[operation.id] = true
    end
  end
  if not next(ids) then return {} end

  return self:_mutate(function()
    for _, operation in ipairs(self.state.operations) do
      if ids[operation.id] then
        remap(operation)
        operation.book_id = tostring(book_id)
        if operation.kind == "note" then
          operation.payload.book_id = tostring(book_id)
        end
      end
    end
    if estimateSize(self.state) > self.max_bytes then
      error("remapped queue exceeds size limit")
    end
    return ids
  end)
end

-- Persist the pause before a remote edition switch. If switching or saving the
-- local link fails, a restart must not send updates to a possibly stale edition.
function SyncQueue:pauseDocument(document)
  for _, operation in ipairs(self.state.operations) do
    if operation.document == document and self.active[operation.id] then
      return nil, "operation_active"
    end
  end
  if self.state.paused_documents[document] then return true end
  return self:_mutate(function()
    self.state.paused_documents[document] = true
    return true
  end)
end

function SyncQueue:resumeDocument(document)
  if not self.state.paused_documents[document] then return true end
  return self:_mutate(function()
    self.state.paused_documents[document] = nil
    return true
  end)
end

function SyncQueue:start()
  if next(self.active) then
    return
  end
  for _, operation in ipairs(self.state.operations) do
    if not self.active[operation.id] and not self.state.paused_documents[operation.document] then
      self.active[operation.id] = true
      return clone(operation)
    end
  end
end

function SyncQueue:finish(operation_id, success)
  if not self.active[operation_id] then
    return false, "not_active"
  end

  local active_operation
  local active_index
  for index, operation in ipairs(self.state.operations) do
    if operation.id == operation_id then
      active_operation = operation
      active_index = index
      break
    end
  end
  self.active[operation_id] = nil
  if not success then
    if active_operation and active_operation.kind == "progress" then
      for _, operation in ipairs(self.state.operations) do
        if operation.id ~= operation_id
            and operation.kind == "progress"
            and operation.document == active_operation.document then
          local removed, err, detail = self:_mutate(function()
            table.remove(self.state.operations, active_index)
            return true
          end)
          if not removed then
            return false, err, detail
          end
          return true, "superseded"
        end
      end
    end
    return false
  end

  if not active_index then
    return false, "not_found"
  end

  local removed, err, detail = self:_mutate(function()
    table.remove(self.state.operations, active_index)
    return true
  end)
  if not removed then
    return false, err, detail
  end
  return true
end

function SyncQueue:removeWhere(predicate)
  if type(predicate) ~= "function" then
    return nil, "invalid_predicate"
  end

  local indexes = {}
  for index, operation in ipairs(self.state.operations) do
    if not self.active[operation.id] and predicate(operation) then
      table.insert(indexes, 1, index)
    end
  end
  if #indexes == 0 then
    return 0
  end

  return self:_mutate(function()
    for _, index in ipairs(indexes) do
      table.remove(self.state.operations, index)
    end
    return #indexes
  end)
end

function SyncQueue:hasPending(document, kind)
  for _, operation in ipairs(self.state.operations) do
    if (document == nil or operation.document == document)
        and (kind == nil or operation.kind == kind) then
      return true
    end
  end
  return false
end

function SyncQueue:count()
  return #self.state.operations
end

function SyncQueue:list()
  return clone(self.state.operations)
end

return SyncQueue
