-- rsh: full control of another computer in the domain, like ssh (domain admins).
--
--   rsh <computer>
--
-- Its screen shows here and your keys go there. Hold Ctrl+T to leave; F12 sends Ctrl+T
-- to the remote computer instead (to stop a program running there).
local args = { ... }
local ui = blockos.ui
local rpc = import("rpc")
local wire = import("wire")
local manage = import("manage")
local remote_shell = import("remote_shell")

local target = args[1]
if not target then
  print("Usage: rsh <computer>")
  return
end
if not (blockos.user and blockos.user.source == "domain") then
  ui.print("Log in with a domain admin account to open a remote shell.", "error")
  return
end
local id = blockos.net and blockos.net.resolve(target)
if not id then
  ui.print("Cannot find " .. target .. ".", "error")
  return
end

local width, height = term.getSize()
local size = { width = width, height = height - 1 }
local options = { relogin = true, retries = 0 }
local opened, err = rpc.call(id, manage.PROTOCOL, "shell_open", size, options)
if not opened then
  ui.print(target .. ": " .. tostring(err), "error")
  return
end
local session = opened.session

local function send(message)
  rednet.send(id, message, remote_shell.PROTOCOL)
end

-- The bottom line says where you are and how to get out.
local function draw_bar()
  local x, y = term.getCursorPos()
  local blink = term.getCursorBlink()
  local text = " rsh " .. target .. "  " .. ui.GLYPHS.dot .. "  Ctrl+T leaves  F12 sends Ctrl+T"
  ui.fill(1, height, width, 1, "bar")
  ui.text_at(1, height, ui.fit(text, width), "bar_text", "bar")
  term.setCursorPos(x, y)
  term.setCursorBlink(blink)
end

term.clear()
draw_bar()
local reason
local ping = os.startTimer(remote_shell.PING_SECONDS)
while true do
  local event = table.pack(os.pullEventRaw())
  local name = event[1]
  if name == "rednet_message" and event[2] == id and event[4] == remote_shell.PROTOCOL then
    local parsed = wire.parse(event[3], "event", remote_shell.SCHEMA)
    if parsed and parsed.data.session == session then
      if parsed.topic == "frame" then
        remote_shell.draw(parsed.data)
        draw_bar()
      elseif parsed.topic == "closed" then
        reason = parsed.data.reason
        break
      end
    end
  elseif name == "terminate" then
    send(wire.event("close", { session = session }))
    reason = "you left"
    break
  elseif name == "key" and event[2] == keys.f12 then
    send(remote_shell.input(session, "terminate"))
  elseif name == "timer" and event[2] == ping then
    send(wire.event("ping", { session = session }))
    ping = os.startTimer(remote_shell.PING_SECONDS)
  elseif remote_shell.INPUT_EVENTS[name] then
    local is_on_bar = name:find("^mouse") and event[4] == height
    local is_f12_up = name == "key_up" and event[2] == keys.f12
    if not is_on_bar and not is_f12_up then
      send(remote_shell.input(session, table.unpack(event, 1, event.n)))
    end
  end
end

term.setCursorBlink(false)
ui.clear()
ui.print("Remote shell on " .. target .. " closed: " .. tostring(reason or "done") .. ".", "dim")
