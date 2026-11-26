-- The network map: layout, item paths, move log, and drawing on both device types.
return function(t)
  local STORAGES = {
    { handle = "pickup", label = "Pickup", role = "input" },
    { handle = "ores", label = "Ores", role = "storage", used = 12, size = 27 },
    { handle = "misc", label = "Misc", role = "storage", used = 3, size = 27 },
    { handle = "out", label = "Output", role = "output", used = 0, size = 27 },
    { handle = "furnace", label = "Furnace", role = "ignore" },
  }

  t.it("inputs and outputs go left, storage right, ignored is only counted", function()
    local map = t.fresh_import()("stock_map")
    local layout = map.layout(STORAGES, 51, 19)
    t.eq(layout.by_handle.pickup.side, "left")
    t.eq(layout.by_handle.out.side, "left")
    t.ok(layout.by_handle.out.y > layout.by_handle.pickup.y + 1, "a gap before the outputs")
    t.eq(layout.by_handle.ores.side, "right")
    t.eq(layout.by_handle.furnace, nil)
    t.eq(layout.ignored, 1)
    for _, node in ipairs(layout.nodes) do
      t.ok(node.x >= 1 and node.x + node.width - 1 <= 51, node.handle .. " fits the screen")
    end
  end)

  t.it("an item's path runs from chest to hub to chest without gaps", function()
    local map = t.fresh_import()("stock_map")
    local layout = map.layout(STORAGES, 51, 19)
    local path = assert(map.path(layout, "pickup", "ores"))
    t.eq(path[1].y, layout.by_handle.pickup.y)
    t.eq(path[#path].y, layout.by_handle.ores.y)
    for index = 2, #path do
      local step = math.abs(path[index].x - path[index - 1].x)
        + math.abs(path[index].y - path[index - 1].y)
      t.ok(step <= layout.hub.width + 1, "cells follow each other (through the hub)")
    end
    t.eq(map.path(layout, "pickup", "furnace"), nil, "ignored blocks are not on the map")
  end)

  t.it("long lists say how many did not fit", function()
    local map = t.fresh_import()("stock_map")
    local many = {}
    for index = 1, 30 do
      many[index] = { handle = "c" .. index, label = "Chest " .. index, role = "storage" }
    end
    local layout = map.layout(many, 39, 13) -- turtle-sized
    t.ok(layout.hidden_right > 0)
    t.eq(#layout.nodes + layout.hidden_right, 30)
  end)

  t.it("a frame draws on the current device type", function()
    local import = t.fresh_import()
    local map = import("stock_map")
    local layout = map.layout(STORAGES, 51, 19)
    local screen = window.create(term.current(), 1, 1, 51, 19, false)
    local previous = term.redirect(screen)
    local ok, err = pcall(map.draw, {
      connection = { describe = "this computer" },
      layout = layout,
      selected = 1,
      markers = { { path = assert(map.path(layout, "pickup", "ores")), position = 3, char = "I" } },
      message = "20 Iron: pickup > ores",
    })
    term.redirect(previous)
    t.ok(ok, err)
    local hub_line = screen.getLine(layout.hub.y)
    t.ok(hub_line:find("STOCK"), hub_line)
  end)

  t.it("the move log hands out only moves newer than asked", function()
    local import = t.fresh_import()
    local stock = import("stock")
    local monitor = {
      config = stock.new_config({ "alice" }),
      totals = {},
      states = {},
      alerts = {},
      move_seq = 2,
      moves = {
        { seq = 1, from = "pickup", to = "ores", item = "iron", label = "Iron", count = 20 },
        { seq = 2, from = "ores", to = "out", item = "iron", label = "Iron", count = 6 },
      },
    }
    local handlers = import("stock_handlers").new(monitor)
    local ctx = { local_admin = true }
    t.eq(#handlers.moves(ctx, {}).moves, 2)
    local newer = handlers.moves(ctx, { since = 1 })
    t.eq(#newer.moves, 1)
    t.eq(newer.moves[1].to, "out")
    t.eq(newer.seq, 2)
  end)
end
