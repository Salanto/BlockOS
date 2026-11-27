-- The wall board: the stack layout, item paths along a row, and drawing on colour
-- and greyscale monitors.
return function(t)
  local DATA = {
    title = "Logistics",
    updated = "12:00",
    rows = { { label = "Iron Ingot", count = 3, limit = 10, is_low = true } },
    nodes = {
      { name = "ground", items = 4, blocks = 3, pos = { x = 0, y = 64, z = 0 } },
      { name = "sky", items = 2, blocks = 2, pos = { x = 9, y = 120, z = 3 } },
      { name = "cellar", items = 1, blocks = 1, is_stale = true },
    },
    storages = {
      { node = "ground", handle = "a", role = "storage", used = 27, size = 27 },
      { node = "ground", handle = "b", role = "storage", used = 1, size = 27 },
      { node = "ground", handle = "in", role = "input" },
      { node = "ground", handle = "furnace", role = "ignore" },
      { node = "sky", handle = "c", role = "storage", used = 20, size = 27 },
      { node = "sky", handle = "out", role = "output" },
      { node = "cellar", handle = "d", role = "storage" },
    },
    alerts = { { time = "11:58", item = "iron", label = "Iron Ingot", is_low = true } },
    moves = { { count = 5, label = "Iron Ingot" } },
  }

  t.it("nodes stack by height, highest first, unplaced ones last", function()
    local wall = t.fresh_import()("logistics_wall")
    local layout = wall.layout(DATA, 60, 20)
    t.eq(layout.rows[1].node.name, "sky")
    t.eq(layout.rows[2].node.name, "ground")
    t.eq(layout.rows[3].node.name, "cellar")
    t.eq(layout.labels[1].text, "y 120")
    t.eq(layout.labels[3].text, "no position")
    t.eq(#layout.by_node.ground.cells, 3, "the ignored furnace has no cell")
    t.eq(layout.by_node.ground.cells[3].handle, "in", "inputs and outputs after storage")
    for _, row in ipairs(layout.rows) do
      t.ok(row.y > 2 and row.y < 20, "rows stay on screen")
      t.ok(row.name_x > layout.bus_x, "the stack is right of the bus")
    end
  end)

  t.it("without GPS there is one stack and no group titles", function()
    local wall = t.fresh_import()("logistics_wall")
    local data = { nodes = { { name = "a" }, { name = "b" } }, storages = {} }
    local layout = wall.layout(data, 60, 20)
    t.eq(#layout.labels, 0)
    t.eq(#layout.rows, 2)
  end)

  t.it("too many nodes or chests say how many did not fit", function()
    local wall = t.fresh_import()("logistics_wall")
    local nodes, storages = {}, {}
    for index = 1, 30 do
      nodes[index] = { name = "n" .. index }
    end
    for index = 1, 80 do
      storages[index] = { node = "n1", handle = "c" .. index, role = "storage" }
    end
    local layout = wall.layout({ nodes = nodes, storages = storages }, 50, 14)
    t.ok(layout.hidden_nodes > 0)
    t.eq(#layout.rows + layout.hidden_nodes, 30)
    local first = layout.by_node.n1
    t.eq(#first.cells + first.hidden_cells, 80)
    t.ok(first.items_x <= 50, "the item count still fits")
  end)

  t.it("an item flies along its node's row", function()
    local wall = t.fresh_import()("logistics_wall")
    local layout = wall.layout(DATA, 60, 20)
    local path = assert(wall.path(layout, "ground", "in", "a"))
    t.eq(path[1].x, layout.by_node.ground.cells[3].x)
    t.eq(path[#path].x, layout.by_node.ground.cells[1].x)
    t.eq(path[1].y, layout.by_node.ground.y)
    t.eq(wall.path(layout, "ground", "furnace", "a"), nil, "ignored blocks are not drawn")
    t.eq(wall.path(layout, "nowhere", "a", "b"), nil)
  end)

  t.it("a crossing runs from one row along the bus into the other", function()
    local wall = t.fresh_import()("logistics_wall")
    local data = {
      nodes = { { name = "a" }, { name = "b" } },
      storages = {
        { node = "a", handle = "s", role = "storage" },
        { node = "a", handle = "p", role = "port" },
        { node = "b", handle = "p", role = "port" },
      },
    }
    local layout = wall.layout(data, 60, 20)
    local path = assert(wall.crossing_path(layout, "a", "b"))
    local a_port = layout.by_node.a.cells[2]
    t.eq(path[1].x, a_port.x, "out of a's port")
    t.eq(path[1].y, layout.by_node.a.y)
    t.eq(path[#path].x, layout.by_node.b.cells[1].x, "into b's port")
    t.eq(path[#path].y, layout.by_node.b.y)
    local on_bus = false
    for _, cell in ipairs(path) do
      on_bus = on_bus or cell.x == layout.bus_x
    end
    t.ok(on_bus, "along the main cable")
    t.eq(wall.crossing_path(layout, "a", "gone"), nil)
  end)

  t.it("the wall draws on colour and greyscale monitors", function()
    local import = t.fresh_import()
    local wall = import("logistics_wall")
    for _, is_colour in ipairs({ true, false }) do
      local screen = window.create(term.current(), 1, 1, 60, 20, false)
      local monitor = setmetatable({ isColour = function() return is_colour end },
        { __index = screen })
      local layout = wall.render(monitor, DATA, {})
      local sky = screen.getLine(layout.by_node.sky.y)
      t.ok(sky:find("sky"), sky)
      t.ok(screen.getLine(layout.by_node.cellar.y):find("STALE"))
      if not is_colour then
        local ground = screen.getLine(layout.by_node.ground.y)
        t.ok(ground:find("#.i", 1, true), "fill shown by characters: " .. ground)
      end
      local left = screen.getLine(layout.controller_y + 1)
      t.ok(left:find("CONTROLLER"), left)
    end
  end)

  t.it("a live wall animates new moves and stops when they arrived", function()
    local import = t.fresh_import()
    local wall = import("logistics_wall")
    local monitor = window.create(term.current(), 1, 1, 60, 20, false)
    local live = wall.live(monitor)
    local data = {}
    for key, value in pairs(DATA) do
      data[key] = value
    end
    live.set_data(data)
    t.eq(live.frame(), false, "nothing in flight")
    live.add_moves({ { node = "ground", from = "in", to = "a", label = "Iron", count = 5 } })
    t.eq(#live.markers, 1)
    local frames = 0
    while live.frame() do
      frames = frames + 1
      t.ok(frames < 20, "the marker arrives")
    end
    t.eq(#live.markers, 0)
    t.eq(live.recent[1].label, "Iron", "the move is listed under MOVES")
  end)

  t.it("item counts per node come from the catalog", function()
    local wall = t.fresh_import()("logistics_wall")
    local nodes = { { name = "a" }, { name = "b" } }
    wall.add_totals(nodes, {
      { item = "iron", nodes = { a = 10, b = 2 } },
      { item = "gold", nodes = { a = 1 } },
    })
    t.eq(nodes[1].items_total, 11)
    t.eq(nodes[2].items_total, 2)
  end)
end
