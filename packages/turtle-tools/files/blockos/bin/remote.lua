-- remote: drive a turtle over rednet.
--
--   remote list          turtles in the domain
--   remote <turtle>      drive it from this computer (keyboard only)
--
-- Needs a domain login; the turtle checks it with the controller on every
-- key press. With wireless modems, driving out of range simply stops it
-- answering (part of the fun).
local args = { ... }
local ui = blockos.ui
local rpc = import("rpc")
local turtle_remote = import("turtle_remote_wire")
local turtle_view = import("turtle_view")

-- Never retried: a lost answer must not make the turtle move twice.
local ACT_OPTIONS = { relogin = true, retries = 0 }

-- Key -> action. Characters only, so every keyboard (and basic computers) works.
local KEYS = {
  w = "forward", s = "back", a = "turn_left", d = "turn_right",
  [" "] = "up", c = "down",
  f = "dig", r = "dig_up", v = "dig_down",
  e = "place", t = "place_up", g = "place_down",
  i = "suck", o = "drop", u = "refuel",
}

local HINTS = {
  "w/s fwd/back  a/d turn  space/c up/down",
  "f/r/v dig  e/t/g place  i/o suck/drop",
  "u refuel  1-9 [ ] slot  z/x layer  m map",
  "l look again  q quit",
}

-- Below this width the map and the inventory take turns (m switches).
local SIDE_BY_SIDE_WIDTH = 45
local INVENTORY_WIDTH = 20

local function print_usage()
  print("Usage: remote list | remote <turtle>")
end

local function fail(message)
  ui.print(tostring(message), "error")
end

-- Turtles from the domain's host list, or (without a domain) the ones this computer
-- heard announce themselves.
local function known_turtles()
  local found, domain = pcall(import, "domain")
  local hosts, err
  if found and domain.is_joined() then
    hosts, err = domain.list_hosts()
  else
    hosts = blockos.net and blockos.net.peers() or {}
  end
  if not hosts then
    return nil, err
  end
  local turtles = {}
  for _, host in ipairs(hosts) do
    if host.kind == "turtle" then
      turtles[#turtles + 1] = host
    end
  end
  return turtles
end

local function list_turtles()
  local turtles, err = known_turtles()
  if not turtles then
    return fail(err)
  end
  ui.title("Turtles")
  if #turtles == 0 then
    ui.print("  (none)", "faint")
    return
  end
  ui.table({
    { title = "TURTLE", key = "hostname" },
    { title = "FUEL", key = function(host) return tostring((host.info or {}).fuel or "?") end },
    { title = "SEEN", key = function(host)
      return host.age and (math.floor(host.age) .. "s ago") or "-"
    end },
  }, turtles)
end

------------------------------------------------------------------------------
-- Driving
------------------------------------------------------------------------------

-- Inventory as a 4x4 grid of counts; the selected slot is highlighted.
local function draw_inventory(info, x, y)
  ui.text_at(x, y, ui.fit("Fuel " .. tostring(info.fuel)
    .. (type(info.fuel) == "number" and ("/" .. tostring(info.fuel_limit)) or ""),
    INVENTORY_WIDTH), "text")
  for row = 0, 3 do
    for column = 1, 4 do
      local slot = row * 4 + column
      local cell = string.format("%3d", info.slots[slot] or 0)
      local cell_role = slot == info.selected and "title" or "dim"
      ui.text_at(x + (column - 1) * 5, y + 2 + row, cell, cell_role)
    end
  end
end

-- The map: what the turtle sees, ahead up (see turtle_view).
local function draw_map(look, view, x, y, width, height)
  if height < 3 or width < 5 then
    return
  end
  local status, status_role = turtle_view.status_text(look, view.layer)
  ui.text_at(x, y, ui.fit(status, width), status_role)
  ui.text_at(x, y + 1, ui.fit(turtle_view.near_text(look), width), "dim")
  for index, row in ipairs(turtle_view.rows(look, width, height - 2, view.layer)) do
    for column = 1, #row.text do
      ui.text_at(x + column - 1, y + 1 + index, row.text:sub(column, column), row.roles[column])
    end
  end
end

local function draw(name, info, look, view, message, role)
  local width, height = ui.size()
  ui.clear()
  ui.header(1, "Remote " .. ui.GLYPHS.dot .. " " .. name, blockos.user and blockos.user.name)
  local hint_top = height - #HINTS
  local body_height = hint_top - 3 -- rows 3 .. above the message line
  local is_wide = width >= SIDE_BY_SIDE_WIDTH
  if info and (is_wide or not view.show_map) then
    draw_inventory(info, 1, 3)
  end
  if look and (is_wide or view.show_map) then
    local map_x = is_wide and (INVENTORY_WIDTH + 2) or 1
    draw_map(look, view, map_x, 3, width - map_x + 1, body_height)
  end
  for index, hint in ipairs(HINTS) do
    ui.line(hint_top + index, ui.fit(hint, width), "faint")
  end
  if message then
    ui.line(hint_top, ui.fit(message, width), role or "dim")
  end
end

-- Key press -> the act request, or nil.
local function request_for(char, info)
  if KEYS[char] then
    return { action = KEYS[char] }
  end
  local digit = tonumber(char)
  if digit and digit >= 1 then
    return { action = "select", slot = digit }
  end
  local selected = info and info.selected or 1
  if char == "[" then
    return { action = "select", slot = (selected - 2) % turtle_remote.INVENTORY_SLOTS + 1 }
  elseif char == "]" then
    return { action = "select", slot = selected % turtle_remote.INVENTORY_SLOTS + 1 }
  end
  return nil
end

local function drive(name)
  if not (blockos.user and blockos.user.source == "domain") then
    return fail("Log in with a domain account to drive turtles.")
  end
  local id = blockos.net and blockos.net.resolve(name)
  if not id then
    return fail("Cannot find " .. name .. ".")
  end
  local info, err = rpc.call(id, turtle_remote.PROTOCOL, "info", nil, { relogin = true })
  if not info then
    return fail(name .. ": " .. tostring(err))
  end

  -- What the turtle sees; asked again after every action (read-only, safe to retry).
  local function look_now()
    return rpc.call(id, turtle_remote.PROTOCOL, "look", {}, { relogin = true })
  end
  local look = look_now()
  local view = { layer = 0, show_map = true }

  local message, role = "Ready.", "ok"
  while true do
    draw(name, info, look, view, message, role)
    local _, char = os.pullEvent("char")
    if char == "q" then
      break
    end
    if char == "z" or char == "x" then
      view.layer = math.max(-2, math.min(2, view.layer + (char == "x" and 1 or -1)))
    elseif char == "m" then
      view.show_map = not view.show_map
    elseif char == "l" then
      look = look_now() or look
    end
    local request = request_for(char, info)
    if request then
      local result, call_error = rpc.call(id, turtle_remote.PROTOCOL, "act", request, ACT_OPTIONS)
      if not result then
        message, role = tostring(call_error), "error"
      else
        info = result.info
        look = look_now() or look
        local label = request.action:gsub("_", " ")
        if result.ok then
          message, role = label, "ok"
        else
          message, role = label .. ": " .. tostring(result.detail or "failed"), "warn"
        end
      end
    end
  end
  ui.clear()
end

------------------------------------------------------------------------------

local command = args[1]
if command == "list" then
  list_turtles()
elseif command then
  drive(command)
else
  print_usage()
end
