local _ = require("gettext")
local QueueMenu = {}

function QueueMenu:items(queue, actions)
  local items = {}
  if queue:isAuthBlocked() then
    items[#items + 1] = { text = _("Update account credentials to resume synchronization"), enabled = false }
  end
  for index, queued in ipairs(queue:list()) do
    local operation = queued
    local uncertain = operation.kind == "note" and operation.delivery_state ~= nil
    local paused = queue:isDocumentPaused(operation.document)
    local filename = operation.document:match("[^/]+$") or operation.document
    local state = uncertain and _("Check delivery") or paused and _("Relink edition")
      or operation.blocked_reason and _("Needs attention")
      or operation.next_attempt_at and _("Waiting to retry") or _("Pending")
    local label = filename .. " — " .. _(operation.kind) .. ": " .. state
    local choices = {}
    if paused then
      choices[#choices + 1] = {
        text = _("Relink the intended edition to resume this document"), enabled = false,
      }
    end
    if operation.kind == "note" then
      choices[#choices + 1] = { text = _("View note"), callback = function()
        actions.show(operation.payload.entry or "")
      end }
    end
    if uncertain then
      choices[#choices + 1] = { text = _("Already present on StoryGraph"), callback = function()
        actions.confirm {
          text = _("Have you checked that this note is present in the StoryGraph reading journal? This will remove the pending copy without sending it again."),
          ok_text = _("Already saved"),
          ok_callback = function() actions.retry(operation.id, true) end,
        }
      end }
      choices[#choices + 1] = { text = _("Not present: send again"), callback = function()
        actions.confirm {
          text = _("Check the StoryGraph reading journal first. Sending again can duplicate the note if the earlier request succeeded."),
          ok_text = _("Send again"),
          ok_callback = function() actions.retry(operation.id, false) end,
        }
      end }
    else
      choices[#choices + 1] = { text = _("Retry now"), callback = function()
        actions.retry(operation.id)
      end }
    end
    items[#items + 1] = { text = label, sub_item_table = choices }
  end
  if #items == 0 then items[1] = { text = _("No pending updates"), enabled = false } end
  return items
end

return QueueMenu
