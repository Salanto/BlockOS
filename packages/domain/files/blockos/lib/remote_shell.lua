--- Remote shell: full control of a joined computer from another one, like ssh.
--
-- On the target, a session runs a real shell (with BlockOS's path) inside a hidden
-- window of the viewer's size. After every step the changed lines of that window go to
-- the viewer as one event; the viewer's keys, characters, pastes and mouse events come
-- back and are fed to the session. The session runs as the domain admin who opened it
-- (blockos.user is swapped in while it runs), so admin-only commands work even when
-- nobody is logged in at the computer itself. Local keyboard input never reaches it.
--
-- Wire (protocol "blockos.manage.shell", wire events):
--   target -> viewer  "frame"  { session, lines = { { y, text, fg, bg } }, x, y, blink }
--                     "closed" { session, reason }
--   viewer -> target  "input"  { session, event = { name, ... } }
--                     "ping"   { session }     (keeps the session alive)
--                     "close"  { session }
-- Sessions close when the shell exits, on "close", or after SESSION_TIMEOUT seconds
-- without input or ping.
-- @module remote_shell

local wire = import("wire")

local remote_shell = {}

remote_shell.PROTOCOL = "blockos.manage.shell"
remote_shell.SESSION_TIMEOUT = 60
remote_shell.PING_SECONDS = 10
remote_shell.MAX_SESSIONS = 2
remote_shell.SHELL_PROGRAM = "/rom/programs/shell.lua"

remote_shell.SCHEMA = {
  session = { type = "string", max = 40 },
  event = { type = "table", optional = true },
  lines = { type = "table", optional = true },
  x = { type = "number", optional = true },
  y = { type = "number", optional = true },
  blink = { type = "boolean", optional = true },
  reason = { type = "string", optional = true },
}

-- Input events a viewer may send; the same events from the local keyboard never reach
-- a session.
local INPUT_EVENTS = {
  key = true, key_up = true, char = true, paste = true, terminate = true,
  mouse_click = true, mouse_up = true, mouse_drag = true, mouse_scroll = true,
}
remote_shell.INPUT_EVENTS = INPUT_EVENTS

--- Transport and timing (tests replace these).
remote_shell.env = {
  send = function(id, message) rednet.send(id, message, remote_shell.PROTOCOL) end,
  clock = function() return os.clock() end,
  parent = function() return term.native() end,
}

local function new_id()
  return string.format("%08x%08x", math.random(0, 0x7fffffff), math.random(0, 0x7fffffff))
end

------------------------------------------------------------------------------
-- Target side
------------------------------------------------------------------------------

--- A set of sessions on the target.
-- @tparam[opt] function program function() run inside each session; default: a shell
--   with BlockOS's path (the boot shell is its parent).
-- @treturn table { open(ctx, user, width, height), handle(event...), count() }
function remote_shell.server(program)
  local sessions = {}
  local server = {}

  program = program or function()
    os.run({ shell = blockos and blockos.boot_shell }, remote_shell.SHELL_PROGRAM)
  end

  local function send(session, topic, data)
    data.session = session.id
    remote_shell.env.send(session.viewer, wire.event(topic, data))
  end

  -- Changed lines since the last frame, plus the cursor.
  local function flush(session)
    local lines = {}
    for y = 1, session.height do
      local text, fg, bg = session.window.getLine(y)
      local key = text .. fg .. bg
      if session.last[y] ~= key then
        session.last[y] = key
        lines[#lines + 1] = { y, text, fg, bg }
      end
    end
    local x, y = session.window.getCursorPos()
    local blink = session.window.getCursorBlink()
    if #lines > 0 or x ~= session.cx or y ~= session.cy or blink ~= session.blink then
      session.cx, session.cy, session.blink = x, y, blink
      send(session, "frame", { lines = lines, x = x, y = y, blink = blink })
    end
  end

  local function close(session, reason)
    if sessions[session.id] then
      sessions[session.id] = nil
      send(session, "closed", { reason = reason })
    end
  end

  -- Run the session until it waits for its next event, as the admin who opened it,
  -- drawing into its own window; then send what changed.
  local function resume(session, ...)
    local event = ...
    if session.filter ~= nil and event ~= session.filter and event ~= "terminate" then
      return
    end
    local previous_term = term.redirect(session.window)
    local previous_user = blockos and blockos.user
    if blockos then
      blockos.user = session.user
    end
    local ok, filter = coroutine.resume(session.routine, ...)
    if blockos then
      blockos.user = previous_user
    end
    term.redirect(previous_term)
    if not ok then
      close(session, tostring(filter))
      return
    end
    session.filter = filter
    if coroutine.status(session.routine) == "dead" then
      flush(session)
      close(session, "the shell exited")
      return
    end
    flush(session)
  end

  --- Start a session for the admin who asked (called by the manage handlers).
  function server.open(ctx, user, width, height)
    local count = 0
    for _ in pairs(sessions) do
      count = count + 1
    end
    if count >= remote_shell.MAX_SESSIONS then
      return nil, "too many remote shells open on this computer"
    end
    local session = {
      id = new_id(),
      viewer = ctx.sender,
      user = {
        name = user.name,
        source = "domain",
        groups = user.groups,
        token = ctx.token,
        is_admin = true,
      },
      width = math.min(width, 164),
      height = math.min(height, 81),
      last = {},
      seen = remote_shell.env.clock(),
    }
    session.window = window.create(remote_shell.env.parent(), 1, 1, session.width, session.height,
      false)
    session.routine = coroutine.create(program)
    sessions[session.id] = session
    resume(session)
    return { session = session.id, width = session.width, height = session.height }
  end

  --- Feed one event from the computer's event loop.
  function server.handle(...)
    local event, sender, message, protocol = ...
    if event == "rednet_message" and protocol == remote_shell.PROTOCOL then
      local parsed = wire.parse(message, "event", remote_shell.SCHEMA)
      local session = parsed and sessions[parsed.data.session]
      if not session or session.viewer ~= sender then
        return
      end
      session.seen = remote_shell.env.clock()
      if parsed.topic == "close" then
        close(session, "closed by the viewer")
      elseif parsed.topic == "input" and type(parsed.data.event) == "table"
        and INPUT_EVENTS[parsed.data.event[1]] then
        resume(session, table.unpack(parsed.data.event))
      end
      return
    end
    if INPUT_EVENTS[event] then
      return -- the computer's own keyboard and mouse belong to its own user
    end
    for _, session in pairs(sessions) do
      resume(session, ...)
    end
    if event == "timer" then
      local now = remote_shell.env.clock()
      for _, session in pairs(sessions) do
        if now - session.seen > remote_shell.SESSION_TIMEOUT then
          close(session, "no answer from the viewer")
        end
      end
    end
  end

  function server.count()
    local count = 0
    for _ in pairs(sessions) do
      count = count + 1
    end
    return count
  end

  return server
end

------------------------------------------------------------------------------
-- Viewer side
------------------------------------------------------------------------------

--- Draw a frame from the target onto the current terminal.
-- @tparam table data { lines, x, y, blink }
function remote_shell.draw(data)
  for _, line in ipairs(data.lines or {}) do
    local y, text, fg, bg = line[1], line[2], line[3], line[4]
    if type(text) == "string" and #text == #fg and #fg == #bg then
      term.setCursorPos(1, y)
      term.blit(text, fg, bg)
    end
  end
  if data.x and data.y then
    term.setCursorPos(data.x, data.y)
  end
  term.setCursorBlink(data.blink == true)
end

--- An input event as a message for the target.
function remote_shell.input(session, ...)
  return wire.event("input", { session = session, event = { ... } })
end

return remote_shell
