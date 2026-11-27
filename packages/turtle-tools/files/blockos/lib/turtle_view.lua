--- The driver's map of what a turtle sees (the answer of op "look", see
-- turtle_remote_wire): top-down and turned with the turtle, so "ahead" is always up.
--
-- Pure functions (no drawing), so tests can check the map as text.
-- @module turtle_view

local turtle_view = {}

-- Same headings as the turtle side: 0 north (-z), 1 east (+x), 2 south (+z), 3 west (-x).
local DIRECTIONS = {
  [0] = { x = 0, z = -1 },
  [1] = { x = 1, z = 0 },
  [2] = { x = 0, z = 1 },
  [3] = { x = -1, z = 0 },
}

--- Glyphs: what kind of block, drawn how. Roles are ui theme roles (greyscale on basic
-- devices, so the glyphs alone must tell blocks apart).
turtle_view.GLYPHS = {
  solid = { char = "#", role = "dim" },
  liquid = { char = "~", role = "bar_dim" },
  lava = { char = "~", role = "error" },
  plant = { char = "&", role = "ok" },
  container = { char = "C", role = "warn" },
  machine = { char = "@", role = "title" },
  floor = { char = ".", role = "faint" },
  unknown = { char = " ", role = "faint" },
  turtle = { char = "\24", role = "title" }, -- an up arrow: the turtle faces up
  turtle_lost = { char = "?", role = "title" }, -- heading not known yet
}

local PATTERNS = {
  { "lava", "lava" },
  { "liquid", "water" },
  { "container", "chest" }, { "container", "barrel" }, { "container", "vault" },
  { "container", "crate" }, { "container", "drawer" }, { "container", "shulker" },
  { "machine", "turtle" }, { "machine", "computer" },
  { "plant", "leaves" }, { "plant", "_log$" }, { "plant", "sapling" },
  { "plant", "flower" }, { "plant", "vine" },
}

--- What kind of block a registry name is.
-- @tparam string name e.g. "minecraft:oak_log"
-- @treturn string a key of GLYPHS
function turtle_view.kind(name)
  if not name or name == "minecraft:air" or name:find("_air$") then
    return "unknown"
  end
  local short = name:gsub("^[^:]*:", "")
  for _, pattern in ipairs(PATTERNS) do
    if short:find(pattern[2]) then
      return pattern[1]
    end
  end
  return "solid"
end

--- A block name for people: "minecraft:oak_log" -> "oak log".
-- @tparam string name
-- @treturn string
function turtle_view.short_name(name)
  if not name or name == "minecraft:air" then
    return "air"
  end
  return (name:gsub("^[^:]*:", ""):gsub("_", " "))
end

-- Blocks by offset: [ "x,y,z" ] = name. Without a scan, what inspect saw.
local function index_blocks(look)
  local blocks = {}
  local scan = look.scan
  if scan and scan.cells then
    for _, cell in ipairs(scan.cells) do
      blocks[cell[1] .. "," .. cell[2] .. "," .. cell[3]] = scan.palette[cell[4]]
    end
    return blocks, true
  end
  return blocks, false
end

--- The map as rows of text and roles.
-- @tparam table look The turtle's answer.
-- @tparam number width
-- @tparam number height
-- @tparam[opt] number layer Height shown, relative to the turtle (default 0).
-- @treturn {table...} rows, each { text = string, roles = { role per character } }
function turtle_view.rows(look, width, height, layer)
  layer = layer or 0
  local heading = look.heading
  local forward = DIRECTIONS[heading or 0]
  local right = DIRECTIONS[((heading or 0) + 1) % 4]
  local blocks, has_scan = index_blocks(look)
  local near = look.near or {}
  local center_x, center_y = math.floor((width + 1) / 2), math.floor((height + 1) / 2)

  -- Without a heading only the turtle's own block is placed (the front is unknown).
  local function block_at(ahead, side, dy)
    if has_scan then
      local x = side * right.x + ahead * forward.x
      local z = side * right.z + ahead * forward.z
      return blocks[x .. "," .. dy .. "," .. z]
    end
    if side == 0 and ahead == 1 and dy == 0 and heading ~= nil then
      return near.front
    elseif side == 0 and ahead == 0 then
      return (dy == -1 and near.down) or (dy == 1 and near.up) or nil
    end
    return nil
  end

  local rows = {}
  for row = 1, height do
    local chars, roles = {}, {}
    for column = 1, width do
      local ahead, side = center_y - row, column - center_x
      local glyph
      if ahead == 0 and side == 0 and layer == 0 then
        glyph = turtle_view.GLYPHS[heading and "turtle" or "turtle_lost"]
      else
        local kind = turtle_view.kind(block_at(ahead, side, layer))
        local below = turtle_view.kind(block_at(ahead, side, layer - 1))
        if kind == "unknown" and below ~= "unknown" then
          kind = "floor" -- nothing here, but something to stand on
        end
        glyph = turtle_view.GLYPHS[kind]
      end
      chars[column], roles[column] = glyph.char, glyph.role
    end
    rows[row] = { text = table.concat(chars), roles = roles }
  end
  return rows
end

--- One line about the turtle's surroundings, e.g. "Ahead stone, up air, down dirt".
-- @tparam table look
-- @treturn string
function turtle_view.near_text(look)
  local near = look.near or {}
  return "Ahead " .. turtle_view.short_name(near.front) .. ", up "
    .. turtle_view.short_name(near.up) .. ", down " .. turtle_view.short_name(near.down)
end

--- The map's status line: facing, position, how fresh the scan is.
-- @tparam table look
-- @tparam number layer
-- @treturn string
-- @treturn string role
function turtle_view.status_text(look, layer)
  local names = { [0] = "N", [1] = "E", [2] = "S", [3] = "W" }
  local parts = { "Facing " .. (look.heading and names[look.heading] or "?") }
  if look.pos then
    parts[#parts + 1] = string.format("%d %d %d", look.pos.x, look.pos.y, look.pos.z)
  end
  if layer ~= 0 then
    parts[#parts + 1] = string.format("layer %+d", layer)
  end
  if not look.has_scanner then
    parts[#parts + 1] = "no Geo Scanner"
    return table.concat(parts, "  "), "warn"
  end
  if look.scan and look.scan.age and look.scan.age > 0 then
    parts[#parts + 1] = "scan " .. look.scan.age .. "s ago"
  end
  return table.concat(parts, "  "), look.scan and "dim" or "warn"
end

return turtle_view
