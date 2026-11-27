--- The wall board: the whole logistics network on a big monitor.
--
-- The controller sits on the left, the nodes are stacked on the right, one row each,
-- joined by a bus (the main network). Each row shows a node's chests as cells coloured
-- by how full they are; item moves fly along the row. Nodes that know their position
-- (GPS) are grouped by height (layers, islands); without GPS there is one stack. Under
-- the controller: low items, recent alerts and recent moves.
--
-- Positions are only used for grouping: the board shows how things are connected, not
-- where they stand. Basic monitors get greyscale and fill shown by characters.
--
-- Data shape:
--   { title, updated, rows (levels, from `status`), nodes (from `nodes`),
--     storages (from `storages`), alerts (oldest first), moves (recent, oldest first) }
-- @module logistics_wall

local ui = import("ui")

local logistics_wall = {}

--- Smallest monitor (in characters) the wall needs; smaller ones get the list board.
logistics_wall.MIN_WIDTH = 50
logistics_wall.MIN_HEIGHT = 14

local NAME_WIDTH = 12
local LEFT_MIN, LEFT_MAX = 16, 26
-- Fill characters for greyscale monitors, from empty to full.
local FILL_CHARS = { ".", ":", "%", "#" }

--- Pick the largest text scale at which the wall fits, if any.
-- @tparam table monitor A wrapped monitor.
-- @treturn boolean Whether the wall fits.
function logistics_wall.fit_scale(monitor)
  for _, scale in ipairs({ 1, 0.5 }) do
    monitor.setTextScale(scale)
    local width, height = monitor.getSize()
    if width >= logistics_wall.MIN_WIDTH and height >= logistics_wall.MIN_HEIGHT then
      return true
    end
  end
  return false
end

------------------------------------------------------------------------------
-- Layout (pure: tested without a screen)
------------------------------------------------------------------------------

local function share_of(block)
  if not block.size or block.size == 0 then
    return nil
  end
  return (block.used or 0) / block.size
end

-- The cells of one node: storage first (in order), then inputs and outputs.
local function cells_of(storages, node)
  local storage, others = {}, {}
  for _, block in ipairs(storages) do
    if block.node == node and block.role ~= "ignore" and not block.is_missing then
      if block.role == "storage" then
        storage[#storage + 1] = block
      else
        others[#others + 1] = block
      end
    end
  end
  for _, block in ipairs(others) do
    storage[#storage + 1] = block
  end
  return storage
end

-- Nodes in groups by height (highest first); nodes without a position last.
local function groups_of(nodes)
  local by_height, heights, unplaced = {}, {}, {}
  for _, node in ipairs(nodes) do
    local y = node.pos and tonumber(node.pos.y)
    if y then
      y = math.floor(y)
      if not by_height[y] then
        by_height[y] = {}
        heights[#heights + 1] = y
      end
      table.insert(by_height[y], node)
    else
      unplaced[#unplaced + 1] = node
    end
  end
  table.sort(heights, function(a, b) return a > b end)
  local groups = {}
  for _, y in ipairs(heights) do
    groups[#groups + 1] = { title = "y " .. y, nodes = by_height[y] }
  end
  if #unplaced > 0 then
    groups[#groups + 1] = { title = #heights > 0 and "no position" or nil, nodes = unplaced }
  end
  return groups
end

--- Work out where everything goes.
-- @tparam table data See the module comment.
-- @tparam number width
-- @tparam number height
-- @treturn table { left_width, bus_x, controller_y, rows = { { node, y, name_x,
--   cells = { { handle, x, block } }, hidden_cells, items_x } }, labels = { { y, text } },
--   hidden_nodes, by_node = { [node] = row } }
function logistics_wall.layout(data, width, height)
  local left_width = math.max(LEFT_MIN, math.min(LEFT_MAX, math.floor(width * 0.3)))
  local bus_x = left_width + 2
  local layout = {
    left_width = left_width,
    bus_x = bus_x,
    controller_y = 3,
    rows = {},
    labels = {},
    hidden_nodes = 0,
    by_node = {},
  }
  local name_x = bus_x + 3
  local cells_x = name_x + NAME_WIDTH + 1
  local items_width = 7
  local cell_room = math.max(1, width - cells_x - items_width)
  local y, last_y = 3, height - 1

  for _, group in ipairs(groups_of(data.nodes or {})) do
    if group.title and y <= last_y then
      layout.labels[#layout.labels + 1] = { y = y, text = group.title }
      y = y + 1
    end
    for _, node in ipairs(group.nodes) do
      if y > last_y then
        layout.hidden_nodes = layout.hidden_nodes + 1
      else
        local row = { node = node, y = y, name_x = name_x, cells = {}, hidden_cells = 0 }
        local cells = cells_of(data.storages or {}, node.name)
        for index, block in ipairs(cells) do
          if index > cell_room then
            row.hidden_cells = row.hidden_cells + 1
          else
            row.cells[#row.cells + 1] = { handle = block.handle, x = cells_x + index - 1,
              block = block }
          end
        end
        row.items_x = cells_x + math.min(#cells, cell_room) + 1
        layout.rows[#layout.rows + 1] = row
        layout.by_node[node.name] = row
        y = y + 1
      end
    end
  end
  layout.bottom = math.max(y - 1, layout.controller_y + 2)
  return layout
end

--- The cells an item passes on its way from one chest to another of the same node.
-- @tparam table layout
-- @tparam string node
-- @tparam string from Handle.
-- @tparam string to Handle.
-- @treturn {table...}|nil { x, y } cells, or nil when a chest is not on the board.
function logistics_wall.path(layout, node, from, to)
  local row = layout.by_node[node]
  if not row then
    return nil
  end
  local from_x, to_x
  for _, cell in ipairs(row.cells) do
    if cell.handle == from then
      from_x = cell.x
    end
    if cell.handle == to then
      to_x = cell.x
    end
  end
  if not (from_x and to_x) then
    return nil
  end
  local path = {}
  local step = to_x >= from_x and 1 or -1
  for x = from_x, to_x, step do
    path[#path + 1] = { x = x, y = row.y }
  end
  -- Linger at the destination so short hops are visible too.
  path[#path + 1] = { x = to_x, y = row.y }
  path[#path + 1] = { x = to_x, y = row.y }
  return path
end

------------------------------------------------------------------------------
-- Drawing
------------------------------------------------------------------------------

local function short_count(count)
  if count >= 10000 then
    return math.floor(count / 1000) .. "k"
  elseif count >= 1000 then
    return string.format("%.1fk", count / 1000)
  end
  return tostring(count)
end

local function fill_role(block)
  if block.role == "input" then
    return "bar_dim"
  elseif block.role == "output" then
    return "key"
  end
  local share = share_of(block)
  if not share then
    return "faint"
  elseif share >= 0.9 then
    return "error"
  elseif share >= 0.7 then
    return "warn"
  end
  return "ok"
end

local function fill_char(block)
  if block.role == "input" then
    return "i"
  elseif block.role == "output" then
    return "o"
  end
  local share = share_of(block) or 0
  return FILL_CHARS[math.min(#FILL_CHARS, math.floor(share * #FILL_CHARS) + 1)]
end

local function draw_cell(cell, y, is_colour)
  if is_colour then
    ui.text_at(cell.x, y, " ", "text", fill_role(cell.block))
  else
    ui.text_at(cell.x, y, fill_char(cell.block), "text")
  end
end

local function draw_stack(layout, is_colour)
  local bus_x = layout.bus_x
  for y = layout.controller_y, layout.bottom do
    ui.text_at(bus_x, y, "|", "faint")
  end
  for _, label in ipairs(layout.labels) do
    ui.text_at(bus_x + 2, label.y, label.text, "faint")
  end
  for _, row in ipairs(layout.rows) do
    local node = row.node
    ui.text_at(bus_x, row.y, "+--", "faint")
    local role = node.is_stale and "warn" or "text"
    ui.text_at(row.name_x, row.y, ui.pad(node.name, NAME_WIDTH), role)
    for _, cell in ipairs(row.cells) do
      draw_cell(cell, row.y, is_colour)
    end
    local text = node.is_stale and "STALE" or short_count(node.items_total or 0)
    if row.hidden_cells > 0 then
      text = "+" .. row.hidden_cells .. " " .. text
    end
    ui.text_at(row.items_x, row.y, text, node.is_stale and "warn" or "dim")
  end
  if layout.hidden_nodes > 0 then
    ui.text_at(bus_x + 2, layout.bottom + 1, "+" .. layout.hidden_nodes .. " more nodes", "faint")
  end
end

-- A titled list under the controller; returns the next free line.
local function draw_widget(y, last_y, width, title, lines)
  if y > last_y or #lines == 0 then
    return y
  end
  ui.text_at(1, y, ui.fit(title, width), "title")
  y = y + 1
  for _, line in ipairs(lines) do
    if y > last_y then
      break
    end
    ui.text_at(1, y, ui.fit(line.text, width), line.role or "dim")
    y = y + 1
  end
  return y + 1
end

local function draw_left(layout, data, height)
  local width = layout.left_width
  local y = layout.controller_y
  ui.fill(1, y, width, 3, "bar")
  ui.text_at(2, y + 1, ui.fit("CONTROLLER", width - 2), "bar_text", "bar")
  ui.text_at(width + 1, y + 1, "-", "faint")
  y = y + 4

  local low = {}
  for _, row in ipairs(data.rows or {}) do
    if row.is_low then
      low[#low + 1] = { text = row.label .. " " .. row.count .. "/" .. row.limit, role = "error" }
    end
  end
  y = draw_widget(y, height - 1, width, "LOW (" .. #low .. ")", low)

  local alerts = {}
  local all_alerts = data.alerts or {}
  for index = #all_alerts, math.max(1, #all_alerts - 3), -1 do
    local alert = all_alerts[index]
    alerts[#alerts + 1] = {
      text = (alert.time and (alert.time .. " ") or "") .. (alert.label or alert.item),
      role = alert.is_low and "warn" or "ok",
    }
  end
  y = draw_widget(y, height - 1, width, "ALERTS", alerts)

  local moves = {}
  local all_moves = data.moves or {}
  for index = #all_moves, math.max(1, #all_moves - 4), -1 do
    local move = all_moves[index]
    moves[#moves + 1] = { text = move.count .. " " .. tostring(move.label) }
  end
  draw_widget(y, height - 1, width, "MOVES", moves)
end

--- Draw the wall on a terminal-like target.
-- @tparam table target A monitor or window.
-- @tparam table data See the module comment.
-- @tparam[opt] {table...} markers { path, position, char } items in flight
-- @treturn table The layout (for paths of new moves).
function logistics_wall.render(target, data, markers)
  local layout
  ui.draw_on(target, function()
    local width, height = ui.size()
    local is_colour = target.isColour()
    layout = logistics_wall.layout(data, width, height)
    ui.clear()
    local low = 0
    for _, row in ipairs(data.rows or {}) do
      if row.is_low then
        low = low + 1
      end
    end
    local right = #(data.nodes or {}) .. " nodes " .. ui.GLYPHS.dot .. " "
      .. (low > 0 and (low .. " low") or "all ok")
      .. (data.updated and (" " .. ui.GLYPHS.dot .. " " .. data.updated) or "")
    ui.header(1, data.title or "Logistics", right)
    draw_left(layout, data, height)
    draw_stack(layout, is_colour)
    for _, marker in ipairs(markers or {}) do
      local cell = marker.path[marker.position]
      if cell then
        ui.text_at(cell.x, cell.y, marker.char, "title", "bg")
      end
    end
  end)
  return layout
end

--- Item totals per node, for the row's item count (nodes only list how many kinds).
-- @tparam {table...} nodes From `nodes`.
-- @tparam {table...} catalog From `catalog` (with per-node counts).
function logistics_wall.add_totals(nodes, catalog)
  local totals = {}
  for _, item in ipairs(catalog or {}) do
    for node, count in pairs(item.nodes or {}) do
      totals[node] = (totals[node] or 0) + count
    end
  end
  for _, node in ipairs(nodes) do
    node.items_total = totals[node.name] or 0
  end
end

------------------------------------------------------------------------------
-- A live wall (animation between data refreshes)
------------------------------------------------------------------------------

--- A wall on one monitor, drawn through a hidden buffer so frames do not flicker.
-- @tparam table monitor A wrapped monitor (text scale already set).
-- @treturn table { set_data(data), add_moves(moves), frame() -> has_markers }
function logistics_wall.live(monitor)
  local width, height = monitor.getSize()
  local buffer = window.create(monitor, 1, 1, width, height, false)
  local wall = { data = { rows = {}, nodes = {}, storages = {} }, markers = {}, recent = {} }
  local layout = logistics_wall.layout(wall.data, width, height)

  function wall.set_data(data)
    data.moves = wall.recent
    wall.data = data
  end

  function wall.add_moves(moves)
    for _, move in ipairs(moves) do
      wall.recent[#wall.recent + 1] = move
      if #wall.recent > 10 then
        table.remove(wall.recent, 1)
      end
      local path = move.node and logistics_wall.path(layout, move.node, move.from, move.to)
      if path and #wall.markers < 12 then
        local char = tostring(move.label or "?"):sub(1, 1):upper()
        wall.markers[#wall.markers + 1] = { path = path, position = 1, char = char }
      end
    end
  end

  --- Draw one frame and move the markers on.
  function wall.frame()
    layout = logistics_wall.render(buffer, wall.data, wall.markers)
    buffer.setVisible(true)
    buffer.setVisible(false)
    local moving = {}
    for _, marker in ipairs(wall.markers) do
      marker.position = marker.position + 1
      if marker.position <= #marker.path then
        moving[#moving + 1] = marker
      end
    end
    wall.markers = moving
    return #moving > 0
  end

  return wall
end

return logistics_wall
