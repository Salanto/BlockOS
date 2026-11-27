--- The network map of one node: the node in the middle, input and output chests
-- on the left, storage on the right, and recent item moves animated along
-- the lines between them. Tab shows the next node.
--
-- CC cannot tell where blocks are or how cables run, so this is a logical
-- map, not the real layout. Advanced devices get coloured boxes, fill bars
-- and mouse clicks; basic devices get plain ASCII. Both work with the
-- keyboard alone (arrows, Enter, q).
-- @module logistics_map

local device = import("device")
local ui = import("ui")

local logistics_map = {}

local HUB_TEXT = " NODE "
local FILL_WIDTH = 6
-- Seconds between animation frames, move polls and layout refreshes.
local FRAME_SECONDS = 0.15
local POLL_SECONDS = 1
local LAYOUT_SECONDS = 10
-- Cells a marker travels per frame, and how many fly at once.
local MARKER_SPEED = 2
local MAX_MARKERS = 8

------------------------------------------------------------------------------
-- Layout (pure: tested without a screen)
------------------------------------------------------------------------------

-- Place one column of rows; the last row says how many did not fit.
local function place_column(rows, column, first_y, last_y)
  local nodes, hidden = {}, 0
  local capacity = last_y - first_y + 1
  for index, row in ipairs(rows) do
    local is_last_slot = index == capacity and #rows > capacity
    if index > capacity or is_last_slot then
      hidden = hidden + 1
    else
      local node = { y = first_y + index - 1 }
      for key, value in pairs(row) do
        node[key] = value
      end
      node.x, node.width, node.side = column.x, column.width, column.side
      nodes[#nodes + 1] = node
    end
  end
  return nodes, hidden
end

--- Work out where everything goes.
-- @tparam {table...} storages From the `storages` operation:
--   { handle, label, role, used?, size? }
-- @tparam number width Screen width.
-- @tparam number height Screen height.
-- @treturn table { hub = { x, y, width }, nodes = {...}, by_handle = {...},
--   hidden_left, hidden_right, ignored, left_bus, right_bus }
function logistics_map.layout(storages, width, height)
  local top, bottom = 3, height - 2
  local hub_width = #HUB_TEXT
  local hub = {
    x = math.floor((width - hub_width) / 2) + 1,
    y = math.floor((top + bottom) / 2),
    width = hub_width,
  }
  local left_bus = hub.x - 2
  local right_bus = hub.x + hub_width + 1
  local left = { side = "left", x = 1, width = math.max(4, left_bus - 2) }
  local right_x = right_bus + 2
  local right = { side = "right", x = right_x, width = math.max(4, width - right_x + 1) }

  -- Left: inputs, a gap, then outputs. Right: storage. Ignored: only counted.
  local left_rows, right_rows, ignored = {}, {}, 0
  local outputs = {}
  -- Configured chests that are gone are listed in the Storage tab, not here.
  local present = {}
  for _, row in ipairs(storages) do
    if not row.is_missing then
      present[#present + 1] = row
    end
  end
  for _, row in ipairs(present) do
    if row.role == "input" or row.role == "port" then
      left_rows[#left_rows + 1] = row
    elseif row.role == "output" then
      outputs[#outputs + 1] = row
    elseif row.role == "storage" then
      right_rows[#right_rows + 1] = row
    else
      ignored = ignored + 1
    end
  end
  if #left_rows > 0 and #outputs > 0 then
    left_rows[#left_rows + 1] = { is_gap = true }
  end
  for _, row in ipairs(outputs) do
    left_rows[#left_rows + 1] = row
  end

  local left_nodes, hidden_left = place_column(left_rows, left, top, bottom)
  local right_nodes, hidden_right = place_column(right_rows, right, top, bottom)
  local nodes, by_handle = {}, {}
  for _, list in ipairs({ left_nodes, right_nodes }) do
    for _, node in ipairs(list) do
      if not node.is_gap then
        nodes[#nodes + 1] = node
        by_handle[node.handle] = node
      end
    end
  end
  return {
    hub = hub,
    nodes = nodes,
    by_handle = by_handle,
    hidden_left = hidden_left,
    hidden_right = hidden_right,
    ignored = ignored,
    left_bus = left_bus,
    right_bus = right_bus,
    bottom = bottom,
  }
end

-- Cells from a node to the hub: along its row to the bus, along the bus to
-- the hub's row, then into the hub.
local function path_to_hub(layout, node)
  local cells = {}
  local hub = layout.hub
  if node.side == "left" then
    for x = node.x + node.width, layout.left_bus do
      cells[#cells + 1] = { x = x, y = node.y }
    end
  else
    for x = node.x - 1, layout.right_bus, -1 do
      cells[#cells + 1] = { x = x, y = node.y }
    end
  end
  local bus = node.side == "left" and layout.left_bus or layout.right_bus
  local step = hub.y >= node.y and 1 or -1
  for y = node.y + step, hub.y, step do
    if y ~= node.y then
      cells[#cells + 1] = { x = bus, y = y }
    end
  end
  local entry = node.side == "left" and (hub.x - 1) or (hub.x + hub.width)
  cells[#cells + 1] = { x = entry, y = hub.y }
  return cells
end

--- The cells an item travels from one inventory to another, through the hub.
-- @tparam table layout From logistics_map.layout.
-- @tparam string from Handle.
-- @tparam string to Handle.
-- @treturn {table...}|nil { x, y } cells, or nil if either is not on screen
function logistics_map.path(layout, from, to)
  local source, target = layout.by_handle[from], layout.by_handle[to]
  if not (source and target) then
    return nil
  end
  local cells = path_to_hub(layout, source)
  local back = path_to_hub(layout, target)
  for index = #back, 1, -1 do
    cells[#cells + 1] = back[index]
  end
  return cells
end

------------------------------------------------------------------------------
-- Drawing
------------------------------------------------------------------------------

local function fill_share(node)
  if not node.size or node.size == 0 then
    return nil
  end
  return math.min(1, (node.used or 0) / node.size)
end

local function draw_lines(layout)
  for _, node in ipairs(layout.nodes) do
    for _, cell in ipairs(path_to_hub(layout, node)) do
      ui.text_at(cell.x, cell.y, "-", "faint")
    end
    local bus = node.side == "left" and layout.left_bus or layout.right_bus
    ui.text_at(bus, node.y, "+", "faint")
  end
  -- Vertical bus lines over the horizontal dashes.
  for _, node in ipairs(layout.nodes) do
    local bus = node.side == "left" and layout.left_bus or layout.right_bus
    local from, to = math.min(node.y, layout.hub.y), math.max(node.y, layout.hub.y)
    for y = from + 1, to - 1 do
      ui.text_at(bus, y, "|", "faint")
    end
  end
end

local ROLE_BACKGROUND = { input = "bar", output = "selected", storage = "panel" }

-- Advanced: a coloured box with a fill bar made of background colours.
local function draw_node_colour(node, is_selected)
  local background = is_selected and "key" or ROLE_BACKGROUND[node.role] or "panel"
  local share = fill_share(node)
  local bar_width = share and math.min(FILL_WIDTH, node.width - 4) or 0
  local label_width = node.width - (bar_width > 0 and bar_width + 1 or 0)
  ui.text_at(node.x, node.y, ui.pad(" " .. node.label, label_width), "panel_text", background)
  if bar_width > 0 then
    local filled = math.floor(bar_width * share + 0.5)
    local bar_x = node.x + label_width
    ui.text_at(bar_x, node.y, " ", "panel_text", background)
    local fill_role = share > 0.9 and "error" or (share > 0.7 and "warn" or "ok")
    ui.fill(bar_x + 1, node.y, filled, 1, fill_role)
    ui.fill(bar_x + 1 + filled, node.y, bar_width - filled, 1, "faint")
  end
end

-- Basic: plain text, "#" and "." for the fill, ">" marks the selection.
local function draw_node_ascii(node, is_selected)
  local share = fill_share(node)
  local bar = ""
  if share then
    local bar_width = math.min(FILL_WIDTH, node.width - 6)
    if bar_width > 0 then
      local filled = math.floor(bar_width * share + 0.5)
      bar = " " .. string.rep("#", filled) .. string.rep(".", bar_width - filled)
    end
  end
  local marker = is_selected and ">" or " "
  local text = marker .. ui.pad(node.label, node.width - 1 - #bar) .. bar
  ui.text_at(node.x, node.y, text, is_selected and "title" or "text")
end

local function draw_hub(layout, is_colour)
  local hub = layout.hub
  if is_colour then
    ui.fill(hub.x, hub.y - 1, hub.width, 3, "bar")
    ui.text_at(hub.x, hub.y, HUB_TEXT, "bar_text", "bar")
  else
    ui.text_at(hub.x, hub.y - 1, "+" .. string.rep("-", hub.width - 2) .. "+", "dim")
    ui.text_at(hub.x, hub.y, "|" .. HUB_TEXT:sub(2, -2) .. "|", "title")
    ui.text_at(hub.x, hub.y + 1, "+" .. string.rep("-", hub.width - 2) .. "+", "dim")
  end
end

local function draw(view)
  local _, height = ui.size()
  local layout = view.layout
  local is_colour = device.is_advanced()
  ui.clear()
  local user = blockos and blockos.user
  local title = "Network " .. ui.GLYPHS.dot .. " " .. tostring(view.node or "?")
  if view.node_names and #view.node_names > 1 then
    title = title .. " (" .. view.node_index .. "/" .. #view.node_names .. ")"
  end
  ui.header(1, title, user and user.name)
  draw_lines(layout)
  draw_hub(layout, is_colour)
  for index, node in ipairs(layout.nodes) do
    local is_selected = index == view.selected
    if is_colour then
      draw_node_colour(node, is_selected)
    else
      draw_node_ascii(node, is_selected)
    end
  end
  if layout.hidden_left > 0 then
    ui.text_at(1, layout.bottom, "+" .. layout.hidden_left .. " more", "faint")
  end
  if layout.hidden_right > 0 then
    ui.text_at(layout.right_bus + 2, layout.bottom, "+" .. layout.hidden_right .. " more", "faint")
  end
  for _, marker in ipairs(view.markers) do
    local cell = marker.path[marker.position]
    if cell then
      ui.text_at(cell.x, cell.y, marker.char, "title")
    end
  end
  if view.message then
    ui.line(height - 1, view.message, view.role or "dim")
  end
  local right = layout.ignored > 0 and (layout.ignored .. " ignored") or nil
  local hints = { { "q", "Quit" }, { "Enter", "Chest" }, { "r", "Refresh" } }
  if view.node_names and #view.node_names > 1 then
    hints[#hints + 1] = { "Tab", "Node" }
  end
  ui.footer(hints, right)
end

--- Draw one frame (exposed for tests).
-- @tparam table view { connection, layout, selected, markers, message?, role? }
logistics_map.draw = draw

------------------------------------------------------------------------------
-- The interactive view
------------------------------------------------------------------------------

--- The node names in a storages list, sorted, and the rows of one node.
-- @tparam {table...} storages Rows with a `node` field.
-- @tparam[opt] string node Which node (default: the first).
-- @treturn {string...} node names
-- @treturn string the node shown
-- @treturn {table...} its rows
function logistics_map.pick_node(storages, node)
  local names, seen = {}, {}
  for _, row in ipairs(storages) do
    local name = row.node or "?"
    if not seen[name] then
      seen[name] = true
      names[#names + 1] = name
    end
  end
  table.sort(names)
  if not seen[node] then
    node = names[1]
  end
  local rows = {}
  for _, row in ipairs(storages) do
    if (row.node or "?") == node then
      rows[#rows + 1] = row
    end
  end
  return names, node, rows
end

local function load_layout(view)
  local storages, err = view.connection.call("storages")
  if not storages then
    view.message, view.role = tostring(err), "error"
    return
  end
  local rows
  view.node_names, view.node, rows = logistics_map.pick_node(storages, view.node)
  view.node_index = 1
  for index, name in ipairs(view.node_names) do
    if name == view.node then
      view.node_index = index
    end
  end
  local width, height = ui.size()
  view.layout = logistics_map.layout(rows, width, height)
  view.selected = math.max(1, math.min(view.selected, #view.layout.nodes))
end

local function next_node(view)
  local names = view.node_names or {}
  if #names > 1 then
    view.node = names[view.node_index % #names + 1]
    view.selected, view.markers = 1, {}
    load_layout(view)
  end
end

local function poll_moves(view)
  local result = view.connection.call("moves", { since = view.seq })
  if not result then
    return
  end
  if result.log ~= view.log then
    -- The hub restarted: its seqs began again. Start over quietly.
    view.log, view.seq = result.log, result.seq
    return
  end
  if view.seq then
    for _, move in ipairs(result.moves) do
      local is_here = move.node == nil or move.node == view.node
      local path = is_here and logistics_map.path(view.layout, move.from, move.to)
      if path and #view.markers < MAX_MARKERS then
        local char = tostring(move.label):sub(1, 1):upper()
        view.markers[#view.markers + 1] = { path = path, position = 1, char = char }
        view.message = move.count .. " " .. tostring(move.label) .. ": "
          .. tostring(move.from) .. " > " .. tostring(move.to)
        view.role = "dim"
      end
    end
  end
  -- The first poll only learns where the log is; old moves are not replayed.
  view.seq = result.seq
end

local function advance_markers(view)
  local still_moving = {}
  for _, marker in ipairs(view.markers) do
    marker.position = marker.position + MARKER_SPEED
    if marker.position <= #marker.path then
      still_moving[#still_moving + 1] = marker
    end
  end
  view.markers = still_moving
end

-- What can be done with one chest: label, role, and for outputs a request.
local function chest_menu(view, node)
  local actions = { "Set label", "Role: storage", "Role: input", "Role: output",
    "Role: ignore", "Role: port" }
  if node.role == "output" then
    actions[#actions + 1] = "Get items here"
  end
  actions[#actions + 1] = "Cancel"
  local choice = actions[ui.menu({ title = node.label, items = actions })]
  local call, success
  -- node/handle: two nodes may have a chest of the same name.
  local ref = node.node and (node.node .. "/" .. node.handle) or node.handle
  if choice == "Set label" then
    local answers = ui.form("Label for " .. node.handle, { { label = "Label: " } })
    if not answers then
      return
    end
    call, success = { storage = ref, label = answers[1] }, "Label set."
  elseif choice and choice:find("^Role: ") then
    local role = choice:sub(7)
    call, success = { storage = ref, role = role }, node.label .. " is now " .. role .. "."
  elseif choice == "Get items here" then
    local answers = ui.form("Get items into " .. node.label,
      { { label = "Item: " }, { label = "How many (64): " } })
    if answers then
      local count = tonumber(answers[2]) or 64
      local result, err = view.connection.call("request",
        { item = answers[1], count = count, output = ref })
      if result then
        view.message = "Moved " .. result.moved .. " " .. tostring(result.label) .. "."
        view.role = result.moved < count and "warn" or "ok"
      else
        view.message, view.role = tostring(err), "error"
      end
    end
    return
  end
  if call then
    local result, err = view.connection.call("set_storage", call)
    view.message, view.role = result and success or tostring(err), result and "ok" or "error"
    load_layout(view)
  end
end

-- Arrow keys: up/down within a column, left/right to the other column.
local function move_selection(view, key)
  local nodes = view.layout.nodes
  local current = nodes[view.selected]
  if not current then
    return
  end
  if key == keys.up or key == keys.down then
    local step = key == keys.up and -1 or 1
    local index = view.selected + step
    while nodes[index] and nodes[index].side ~= current.side do
      index = index + step
    end
    if nodes[index] then
      view.selected = index
    end
  elseif key == keys.left or key == keys.right then
    local wanted = key == keys.left and "left" or "right"
    local best, best_distance = nil, math.huge
    for index, node in ipairs(nodes) do
      local distance = math.abs(node.y - current.y)
      if node.side == wanted and distance < best_distance then
        best, best_distance = index, distance
      end
    end
    view.selected = best or view.selected
  end
end

local function node_at(view, x, y)
  for index, node in ipairs(view.layout.nodes) do
    if y == node.y and x >= node.x and x < node.x + node.width then
      return index
    end
  end
  return nil
end

--- Show the map until q is pressed.
-- @tparam table connection From logistics_client.connect.
function logistics_map.run(connection)
  local view = { connection = connection, selected = 1, markers = {}, seq = nil }
  load_layout(view)
  if not view.layout then
    return nil, view.message
  end
  poll_moves(view)
  local frame = os.startTimer(FRAME_SECONDS)
  local next_poll, next_layout = os.clock() + POLL_SECONDS, os.clock() + LAYOUT_SECONDS
  while true do
    draw(view)
    local event, a, b, c = os.pullEvent()
    if event == "timer" and a == frame then
      advance_markers(view)
      if os.clock() >= next_poll then
        poll_moves(view)
        next_poll = os.clock() + POLL_SECONDS
      end
      if os.clock() >= next_layout then
        load_layout(view)
        next_layout = os.clock() + LAYOUT_SECONDS
      end
      frame = os.startTimer(FRAME_SECONDS)
    elseif event == "char" and a == "q" then
      break
    elseif event == "char" and a == "r" then
      load_layout(view)
    elseif event == "key" and a == keys.tab then
      next_node(view)
    elseif event == "key" and a == keys.enter then
      local node = view.layout.nodes[view.selected]
      if node then
        chest_menu(view, node)
        -- The menu swallowed the frame timer: start a new one.
        frame = os.startTimer(FRAME_SECONDS)
      end
    elseif event == "key" then
      move_selection(view, a)
    elseif event == "mouse_click" then
      local index = node_at(view, b, c)
      if index then
        view.selected = index
        chest_menu(view, view.layout.nodes[index])
        frame = os.startTimer(FRAME_SECONDS)
      end
    elseif event == "term_resize" then
      load_layout(view)
    end
  end
  ui.clear()
  return true
end

return logistics_map
