-- Conservative, read-only recognition of StoryGraph's journal HTML.
-- Unknown markup is inconclusive, never evidence that a note was not saved.
local htmlparser = require("htmlparser")
local Journal = {}

local function decode(text)
  if type(text) ~= "string" then return nil end
  local valid = true
  local named = { amp = "&", lt = "<", gt = ">", quot = '"', apos = "'", nbsp = "\194\160" }
  local result = text:gsub("&([^;]+);", function(entity)
    if named[entity] then return named[entity] end
    local hex = entity:match("^#[xX]([%da-fA-F]+)$")
    local n = tonumber(entity:match("^#(%d+)$")) or (hex and tonumber(hex, 16))
    if not n or n < 1 or n > 0x10ffff or (n >= 0xd800 and n <= 0xdfff) then
      valid = false
      return ""
    end
    if n < 128 then return string.char(n) end
    if n < 2048 then return string.char(192 + math.floor(n / 64), 128 + n % 64) end
    if n < 65536 then
      return string.char(224 + math.floor(n / 4096), 128 + math.floor(n / 64) % 64, 128 + n % 64)
    end
    return string.char(240 + math.floor(n / 262144), 128 + math.floor(n / 4096) % 64,
      128 + math.floor(n / 64) % 64, 128 + n % 64)
  end)
  return valid and result or nil
end

local function document(html)
  if type(html) ~= "string" then return nil end
  local root = htmlparser.parse(html)
  for _, form in ipairs(root:select("form")) do
    if (form.attributes.action or ""):find("/users/sign_in", 1, true) then return nil end
  end
  return root
end

function Journal:snapshot(html, book_id)
  local root = document(html)
  if not root then return nil end
  local panes = root:select(".journal-entry-panes")
  if #panes ~= 1 then return nil end
  -- Do not infer absence from a partial/paginated journal.
  for _, node in ipairs(root:select("a")) do
    local href = decode(node.attributes.href or "")
    if not href or node.attributes.rel == "next"
        or (href:match("^/journal%?") and href ~= "/journal?book_id=" .. book_id) then return nil end
  end
  if #root:select(".pagination") > 0 then return nil end
  for _, frame in ipairs(root:select("turbo-frame")) do
    if frame.attributes.src then return nil end
  end
  local scoped = false
  for _, link in ipairs(panes[1].parent:select("a")) do
    local target = (link.attributes.href or ""):match("^/books/([^/?]+)$")
    if target then
      if target ~= book_id then return nil end
      scoped = true
    end
  end
  if not scoped then return nil end
  local ids, count = {}, 0
  for _, link in ipairs(panes[1]:select("a")) do
    local href = decode(link.attributes.href or "")
    local id = href and href:match("^/journal_entries/([%w%-]+)/edit%?")
    if not href or (href:find("/journal_entries/", 1, true) and not id) then return nil end
    if id and not ids[id] then ids[id], count = true, count + 1 end
  end
  if count > 200 then return nil end
  return ids
end

function Journal:newEntry(before, after)
  if not before or not after then return nil end
  -- Disappearing entries may indicate an incomplete page or concurrent edits.
  for id in pairs(before) do if not after[id] then return nil end end
  local new_id
  for id in pairs(after) do
    if not before[id] then
      if new_id then return nil end
      new_id = id
    end
  end
  return new_id
end

local function value(form, name)
  local values = {}
  for _, node in ipairs(form:select("input")) do
    if node.attributes.name == name then values[#values + 1] = decode(node.attributes.value) or false end
  end
  for _, node in ipairs(form:select("select")) do
    if node.attributes.name == name then
      for _, option in ipairs(node:select("option")) do
        if option.attributes.selected ~= nil then
          values[#values + 1] = decode(option.attributes.value) or false
        end
      end
    end
  end
  return #values == 1 and values[1] or nil
end

local function plainNote(html)
  if not html then return nil end
  -- Only the simple rich-text wrapper produced for plugin notes is supported.
  -- Do not erase formatting/attachments and accidentally match different notes.
  html = html:gsub("\r\n", "\n")
  html = html:match("^<div>(.*)</div>$") or html
  html = html:gsub("<br%s*/?>", "\n")
  if html:find("[<>]") then return nil end
  return decode(html)
end

function Journal:matches(html, id, note)
  local root = document(html)
  if not root or type(note.date) ~= "table" or type(note.entry) ~= "string" or note.entry == "" then return false end
  local forms = {}
  for _, form in ipairs(root:select("form")) do
    if form.attributes.action == "/journal_entries/" .. id then forms[#forms + 1] = form end
  end
  if #forms ~= 1 then return false end
  local form = forms[1]
  if plainNote(value(form, "journal_entry[note]")) ~= note.entry:gsub("\r\n", "\n") then return false end
  for _, part in ipairs({ "day", "month", "year" }) do
    local expected = tonumber(note.date[part])
    if not expected or tonumber(value(form, "journal_entry[" .. part .. "]")) ~= expected then return false end
  end
  local field = note.progress_type == "pages" and "pages_read_total"
    or note.progress_type == "percentage" and "percent_reached"
  local expected = tonumber(note.progress)
  return field ~= false and field ~= nil and expected ~= nil
    and tonumber(value(form, "journal_entry[" .. field .. "]")) == expected
end

return Journal
