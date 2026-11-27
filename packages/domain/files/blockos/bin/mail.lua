-- mail: messages between the players of a domain, kept by the domain controller and
-- read on any computer.
--
--   mail                         your messages, newest first (* = new)
--   mail read <n>                show message n (and mark it read)
--   mail send <user|group> <text...>
--                                a group sends to each of its members
--   mail delete <n>
--
-- Joined computers send notices too (from their hostname).
local args = { ... }
local ui = blockos.ui
local domain = import("domain")

local function print_usage()
  print("Usage: mail | mail read <n> | mail delete <n>")
  print("       mail send <user|group> <text...>")
end

local function fail(message)
  ui.print(tostring(message), "error")
end

local function age(time)
  if not time then
    return "?"
  end
  local seconds = math.max(0, math.floor(os.epoch("utc") / 1000) - time)
  if seconds < 3600 then
    return math.floor(seconds / 60) .. "m"
  elseif seconds < 86400 then
    return math.floor(seconds / 3600) .. "h"
  end
  return math.floor(seconds / 86400) .. "d"
end

local function list(messages)
  ui.title("Mail of " .. blockos.user.name)
  if #messages == 0 then
    ui.print("  (no messages)", "faint")
    return
  end
  local width = ui.size()
  for index, message in ipairs(messages) do
    local mark = message.is_read and " " or "*"
    local head = string.format("%s%2d %-10s %4s ", mark, index, ui.fit(message.from, 10),
      age(message.time))
    local role = message.is_read and "dim" or "text"
    ui.print(head .. ui.fit(message.text, math.max(1, width - #head)), role)
  end
end

local function pick(messages, number)
  local message = messages[tonumber(number or "")]
  if not message then
    return nil, "No message " .. tostring(number) .. " (see 'mail')."
  end
  return message
end

local function read_message(messages, number)
  local message, err = pick(messages, number)
  if not message then
    return fail(err)
  end
  ui.title("From " .. message.from .. (message.to ~= blockos.user.name
    and (" to " .. message.to) or "") .. ", " .. age(message.time) .. " ago")
  print(message.text)
  if not message.is_read then
    domain.call("mail_read", { id = message.id })
  end
end

local function delete_message(messages, number)
  local message, err = pick(messages, number)
  if not message then
    return fail(err)
  end
  local ok, delete_error = domain.call("mail_delete", { id = message.id })
  if not ok then
    return fail(delete_error)
  end
  ui.print("Deleted.", "ok")
end

local function send(to, text)
  if not to or text == "" then
    return print_usage()
  end
  local result, err = domain.call("mail_send", { to = to, text = text })
  if not result then
    return fail(err)
  end
  ui.print("Sent to " .. result.sent .. " user" .. (result.sent == 1 and "" or "s") .. ".", "ok")
end

if not (blockos.user and blockos.user.source == "domain") then
  return fail("Log in with a domain account: mail is kept by the domain.")
end

local command = args[1]
if command == "send" then
  return send(args[2], table.concat(args, " ", 3))
end
local messages, err = domain.call("mail_list")
if not messages then
  return fail(err)
end
if command == nil then
  list(messages)
elseif command == "read" then
  read_message(messages, args[2])
elseif command == "delete" then
  delete_message(messages, args[2])
else
  print_usage()
end
if blockos.notices and command ~= nil then
  local unread = 0
  for _, message in ipairs(domain.call("mail_list") or {}) do
    unread = unread + (message.is_read and 0 or 1)
  end
  blockos.notices.mail = unread > 0 and (unread .. " new message(s): type 'mail'") or nil
end
