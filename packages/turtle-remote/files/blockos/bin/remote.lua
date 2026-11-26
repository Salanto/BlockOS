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
local turtle_remote = import("turtle_remote")

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
  "f/r/v dig fwd/up/down  e/t/g place",
  "i suck  o drop  u refuel  1-9 [ ] slot",
  "q quit",
}

local function print_usage()
  print("Usage: remote list | remote <turtle>")
end

local function fail(message)
  ui.print(tostring(message), "error")
end

local function list_turtles()
  local domain = import("domain")
  local hosts, err = domain.list_hosts()
  if not hosts then
    return fail(err)
  end
  local turtles = {}
  for _, host in ipairs(hosts) do
    if host.kind == "turtle" then
      turtles[#turtles + 1] = host
    end
  end
  ui.title("Turtles in the domain")
  if #turtles == 0 then
    ui.print("  (none)", "faint")
    return
  end
  ui.table({
    { title = "TURTLE", key = "hostname" },
    { title = "FUEL", key = function(host) return tostring(host.info.fuel or "?") end },
    { title = "SEEN", key = function(host) return domain.describe_seen(host) end },
  }, turtles)
end

------------------------------------------------------------------------------
-- Driving
------------------------------------------------------------------------------

local function draw(name, info, message, role)
  local width, height = ui.size()
  ui.clear()
  ui.header(1, "Remote " .. ui.GLYPHS.dot .. " " .. name, blockos.user and blockos.user.name)
  if info then
    local fuel = tostring(info.fuel)
    if type(info.fuel) == "number" then
      fuel = fuel .. "/" .. tostring(info.fuel_limit)
    end
    ui.line(3, "Fuel " .. fuel .. "   slot " .. tostring(info.selected), "text")
    -- Inventory as a 4x4 grid of counts; the selected slot is highlighted.
    for row = 0, 3 do
      local x = 1
      for column = 1, 4 do
        local slot = row * 4 + column
        local cell = string.format("%3d", info.slots[slot] or 0)
        local cell_role = slot == info.selected and "title" or "dim"
        ui.text_at(x, 5 + row, cell, cell_role)
        x = x + 5
      end
    end
  end
  local hint_top = height - #HINTS
  for index, hint in ipairs(HINTS) do
    ui.line(hint_top + index, ui.fit(hint, width), "faint")
  end
  if message then
    ui.line(hint_top - 1, message, role or "dim")
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

  local message, role = "Ready.", "ok"
  while true do
    draw(name, info, message, role)
    local _, char = os.pullEvent("char")
    if char == "q" then
      break
    end
    local request = request_for(char, info)
    if request then
      local result, call_error = rpc.call(id, turtle_remote.PROTOCOL, "act", request, ACT_OPTIONS)
      if not result then
        message, role = tostring(call_error), "error"
      else
        info = result.info
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
