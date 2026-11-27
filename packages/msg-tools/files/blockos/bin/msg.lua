-- msg: chat with other computers.
--
--   msg                     show received messages (and mark them read)
--   msg <host> <text...>    send a message to one computer
--   msg * <text...>         send a message to every computer in range
local args = { ... }
local ui = blockos.ui
local net = blockos.net
local messages = import("messages")

local function show_inbox()
  local box = blockos.messages or { inbox = {}, unread = 0 }
  ui.title("Messages")
  if #box.inbox == 0 then
    ui.print("  (none yet)", "faint")
  end
  for _, message in ipairs(box.inbox) do
    ui.use("faint")
    write(message.time .. " ")
    ui.use("title")
    write(message.from .. ": ")
    ui.print(message.text)
  end
  box.unread = 0
  import("notices").clear("msg")
end

local function send(target, text)
  if not net or not net.is_online() then
    return ui.print("Offline: no modem attached.", "error")
  end
  local event = messages.event(text)
  if target == "*" then
    rednet.broadcast(event, messages.PROTOCOL)
    return ui.print("Sent to everyone in range.", "ok")
  end
  local id = net.resolve(target)
  if not id then
    return ui.print("Cannot find " .. target .. ".", "error")
  end
  rednet.send(id, event, messages.PROTOCOL)
  ui.print("Sent to " .. target .. ".", "ok")
end

if #args == 0 then
  show_inbox()
elseif #args == 1 then
  print("Usage: msg | msg <host> <text...> | msg * <text...>")
else
  send(args[1], table.concat(args, " ", 2))
end
