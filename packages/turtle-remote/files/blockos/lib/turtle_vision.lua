--- What a turtle sees, for its remote driver (op "look" of protocol blockos.remote).
--
-- Always: the blocks in front, above and below (turtle.inspect*, free). With a Geo
-- Scanner (Advanced Peripherals, peripheral type "geoScanner", e.g. the turtle upgrade):
-- the blocks around it. A scan takes ~2 s to recharge (AP config scanBlocksCooldown),
-- so the last scan is kept and shifted as the turtle moves; radius up to 8 is free
-- (scanBlocksMaxFreeRadius), up to 16 costs fuel.
--
-- Scans use world axes. To draw "ahead" up the driver needs the heading, which the
-- turtle learns from GPS after a move, or by matching the block in front against the
-- scan, and then follows through turns. Position is tracked the same way (GPS when
-- there are hosts, else relative to where it started).
--
-- Read-only: inspect and scan never move the turtle (see CLAUDE.md, device rules).
-- @module turtle_vision

local turtle_vision = {}

--- Headings: 0 north (-z), 1 east (+x), 2 south (+z), 3 west (-x).
turtle_vision.DIRECTIONS = {
  [0] = { x = 0, z = -1 },
  [1] = { x = 1, z = 0 },
  [2] = { x = 0, z = 1 },
  [3] = { x = -1, z = 0 },
}
turtle_vision.HEADING_NAMES = { [0] = "north", [1] = "east", [2] = "south", [3] = "west" }

--- Scan radius used when the driver asks for none (the free radius).
turtle_vision.DEFAULT_RADIUS = 8
turtle_vision.MAX_RADIUS = 16
--- Seconds between scans (AP's default cooldown is 2 s; a little slack).
turtle_vision.SCAN_SECONDS = 2.2
--- Layers sent around the turtle's height (keeps the answer small).
turtle_vision.LAYERS = 2

--- Hardware access (tests replace these).
turtle_vision.env = {
  find_scanner = function()
    return peripheral.find("geoScanner")
  end,
  locate = function()
    return import("net").position()
  end,
  clock = os.clock,
}

local function key_of(x, y, z)
  return x .. "," .. y .. "," .. z
end

--- Make the vision of one turtle.
-- @tparam table turtle_api The turtle API (tests pass a stub).
-- @treturn table vision with look(radius) and after_action(action, ok)
function turtle_vision.new(turtle_api)
  local env = turtle_vision.env
  local vision = {
    heading = nil, -- 0..3 once known
    pos = { x = 0, y = 0, z = 0 }, -- world (is_gps) or relative to the start
    is_gps = false,
    scan = nil, -- { at = pos copy, blocks = { [key] = block }, radius, clock }
  }

  local function copy(pos)
    return { x = pos.x, y = pos.y, z = pos.z }
  end

  local function name_of(ok, data)
    if ok and type(data) == "table" then
      return data.name
    end
    return "minecraft:air"
  end

  local function near()
    return {
      front = name_of(turtle_api.inspect()),
      up = name_of(turtle_api.inspectUp()),
      down = name_of(turtle_api.inspectDown()),
    }
  end

  -- GPS when available; keeps the old position otherwise.
  local function locate()
    local found = env.locate()
    if found then
      vision.pos, vision.is_gps = found, true
    end
    return found
  end

  -- Learn the heading by matching the block in front against the scan: the neighbour
  -- at turtle height whose block matches (air = not in the scan), if only one does.
  local function heading_from_scan(front)
    if not vision.scan or vision.heading then
      return
    end
    local offset = {
      x = vision.pos.x - vision.scan.at.x,
      y = vision.pos.y - vision.scan.at.y,
      z = vision.pos.z - vision.scan.at.z,
    }
    local match = nil
    for heading = 0, 3 do
      local step = turtle_vision.DIRECTIONS[heading]
      local block = vision.scan.blocks[key_of(offset.x + step.x, offset.y, offset.z + step.z)]
      local name = block and block.name or "minecraft:air"
      if name == front then
        if match then
          return -- two match: not sure
        end
        match = heading
      end
    end
    vision.heading = match
  end

  local function scan(radius)
    local scanner = env.find_scanner()
    if not scanner then
      return nil, "no Geo Scanner"
    end
    if vision.scan and env.clock() - vision.scan.clock < turtle_vision.SCAN_SECONDS then
      return vision.scan -- still recharging: the kept scan will do
    end
    local ok, blocks, err = pcall(scanner.scan, radius)
    if not ok or type(blocks) ~= "table" then
      return nil, tostring(ok and err or blocks)
    end
    local kept = {}
    for _, block in ipairs(blocks) do
      if type(block.x) == "number" and block.name ~= "minecraft:air" then
        local x, y, z = block.x, block.y, block.z
        -- Offsets from the scanner (what AP returns); world coordinates are turned
        -- into offsets when the position is known from GPS.
        if math.abs(x) > radius or math.abs(y) > radius or math.abs(z) > radius then
          x, y, z = x - vision.pos.x, y - vision.pos.y, z - vision.pos.z
        end
        kept[key_of(x, y, z)] = { name = block.name, x = x, y = y, z = z }
      end
    end
    vision.scan = { at = copy(vision.pos), blocks = kept, radius = radius, clock = env.clock() }
    return vision.scan
  end

  --- What the turtle sees now.
  -- @tparam[opt] number radius Scan radius (default DEFAULT_RADIUS, at most MAX_RADIUS).
  -- @treturn table { near = { front, up, down }, heading?, pos?, has_scanner, scan_error?,
  --   scan? = { radius, age, is_shifted, palette = { name... }, cells = { { x, y, z, p } } } }
  --   with x/y/z offsets from the turtle in world axes
  function vision.look(radius)
    radius = math.min(math.max(math.floor(radius or turtle_vision.DEFAULT_RADIUS), 1),
      turtle_vision.MAX_RADIUS)
    if not vision.is_gps then
      locate()
    end
    local seen = near()
    local result = { near = seen, heading = vision.heading,
      pos = vision.is_gps and copy(vision.pos) or nil }
    local current, err = scan(radius)
    result.has_scanner = err ~= "no Geo Scanner"
    result.scan_error = err
    if current then
      heading_from_scan(seen.front)
      result.heading = vision.heading
      result.scan = turtle_vision.slice(current, vision.pos, env.clock())
    end
    return result
  end

  --- Follow a driver's action (only successful ones change anything).
  -- @tparam string action An action name (turtle_remote_wire.ACTIONS).
  -- @tparam boolean ok Did it work?
  function vision.after_action(action, ok)
    if not ok then
      return
    end
    if action == "turn_left" or action == "turn_right" then
      if vision.heading then
        vision.heading = (vision.heading + (action == "turn_right" and 1 or 3)) % 4
      end
    elseif action == "up" or action == "down" then
      vision.pos.y = vision.pos.y + (action == "up" and 1 or -1)
    elseif action == "forward" or action == "back" then
      local sign = action == "forward" and 1 or -1
      if vision.heading then
        local step = turtle_vision.DIRECTIONS[vision.heading]
        vision.pos.x = vision.pos.x + sign * step.x
        vision.pos.z = vision.pos.z + sign * step.z
      else
        -- Unknown heading: GPS before and after tells it; without GPS the kept scan
        -- can no longer be placed.
        local before = vision.is_gps and copy(vision.pos) or nil
        local after = before and locate()
        if after then
          local dx, dz = (after.x - before.x) * sign, (after.z - before.z) * sign
          for heading, step in pairs(turtle_vision.DIRECTIONS) do
            if step.x == dx and step.z == dz then
              vision.heading = heading
            end
          end
        else
          vision.scan = nil
        end
      end
    end
  end

  return vision
end

--- The part of a scan the driver draws: the layers around the turtle, shifted to its
-- current position, as a palette and cells.
-- @tparam table scan A kept scan.
-- @tparam table pos The turtle's position now.
-- @tparam number now Clock.
-- @treturn table scan for the answer
function turtle_vision.slice(scan, pos, now)
  local shift = { x = scan.at.x - pos.x, y = scan.at.y - pos.y, z = scan.at.z - pos.z }
  local palette, index_of, cells = {}, {}, {}
  for _, block in pairs(scan.blocks) do
    local x, y, z = block.x + shift.x, block.y + shift.y, block.z + shift.z
    if math.abs(y) <= turtle_vision.LAYERS then
      local index = index_of[block.name]
      if not index then
        palette[#palette + 1] = block.name
        index = #palette
        index_of[block.name] = index
      end
      cells[#cells + 1] = { x, y, z, index }
    end
  end
  local moved = shift.x ~= 0 or shift.y ~= 0 or shift.z ~= 0
  return {
    radius = scan.radius,
    age = math.floor(now - scan.clock),
    is_shifted = moved,
    palette = palette,
    cells = cells,
  }
end

return turtle_vision
