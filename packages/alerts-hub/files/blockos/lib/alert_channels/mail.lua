--- Alert channel: a BlockOS mail to a domain user or group (needs a mail server, and
-- the hub's computer in the domain: joined computers may send notices).
-- @module alert_channels.mail

local mail = {}

mail.kind = "mail"
mail.help = "a domain user or group (needs a mail server)"

local MAX_SUBJECT = 40
local MAX_TEXT = 300

--- @tparam string target
-- @treturn[1] true
-- @treturn[2] nil
-- @treturn[2] string what is wrong
function mail.check(target)
  if not target:match("^[%w_%-%.]+$") or #target > 32 then
    return nil, "expected a user or group name"
  end
  return true
end

--- @tparam string target
-- @treturn string
function mail.describe(target)
  return "mail to " .. target
end

--- Subject and text of the mail for an alert.
-- @tparam table alert
-- @treturn string subject
-- @treturn string text
function mail.compose(alert)
  local subject = ("[" .. alert.level .. "] " .. alert.title):sub(1, MAX_SUBJECT)
  local lines = { alert.title }
  if alert.text then
    lines[#lines + 1] = alert.text
  end
  lines[#lines + 1] = "(" .. alert.source .. " on " .. tostring(alert.host) .. ")"
  return subject, table.concat(lines, "\n"):sub(1, MAX_TEXT)
end

--- Send an alert.
-- @tparam string target
-- @tparam table alert
-- @tparam table env { mail = function(to, subject, text) -> result | nil, err }
-- @treturn[1] true
-- @treturn[2] nil
-- @treturn[2] string error message
function mail.deliver(target, alert, env)
  local subject, text = mail.compose(alert)
  local result, err = env.mail(target, subject, text)
  if not result then
    return nil, err
  end
  return true
end

return mail
