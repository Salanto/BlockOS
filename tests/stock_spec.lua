-- StorageMonitor logic: limits, recovery margin, outputs, filling from storage, access.
return function(t)
  local function config_with(watches)
    local stock = t.fresh_import()("stock")
    local config = stock.new_config({ "alice" })
    config.watches = watches
    return stock, config
  end

  t.it("items go low below their limit and recover above a margin", function()
    local stock, config = config_with({ ["minecraft:iron_ingot"] = { label = "Iron", limit = 100 } })
    local function at(count, previous)
      return stock.evaluate(config, { ["minecraft:iron_ingot"] = { count = count } }, previous)
    end
    local states, changes = at(120)
    t.ok(not states["minecraft:iron_ingot"].is_low)
    states, changes = at(99, states)
    t.ok(states["minecraft:iron_ingot"].is_low)
    t.eq(changes.went_low[1], "minecraft:iron_ingot")
    states, changes = at(102, states)
    t.ok(states["minecraft:iron_ingot"].is_low, "still low inside the margin")
    t.eq(#changes.recovered, 0)
    states, changes = at(105, states)
    t.ok(not states["minecraft:iron_ingot"].is_low)
    t.eq(changes.recovered[1], "minecraft:iron_ingot")
  end)

  t.it("items missing from storage count as zero", function()
    local stock, config = config_with({ ["minecraft:gold_ingot"] = { label = "Gold", limit = 1 } })
    local states = stock.evaluate(config, {})
    t.eq(states["minecraft:gold_ingot"].count, 0)
    t.ok(states["minecraft:gold_ingot"].is_low)
  end)

  t.it("an output is on while any item mapped to it is low", function()
    local lamp = { target = "redstone_relay_0", side = "top" }
    local stock, config = config_with({
      a = { label = "A", limit = 10, outputs = { lamp } },
      b = { label = "B", limit = 10, outputs = { lamp } },
    })
    config.any_low_outputs = { { target = "computer", side = "back" } }
    local states = stock.evaluate(config, { a = { count = 50 }, b = { count = 50 } })
    local outputs = stock.output_states(config, states)
    t.ok(not outputs["redstone_relay_0|top"].is_on)
    t.ok(not outputs["computer|back"].is_on)
    states = stock.evaluate(config, { a = { count = 50 }, b = { count = 1 } })
    outputs = stock.output_states(config, states)
    t.ok(outputs["redstone_relay_0|top"].is_on)
    t.ok(outputs["computer|back"].is_on, "the any-low output follows any item")
  end)

  t.it("the watch list can be filled from storage contents", function()
    local stock, config = config_with({ existing = { label = "Kept", limit = 7 } })
    local totals = {
      existing = { count = 100, label = "Kept" },
      cobble = { count = 640, label = "Cobblestone" },
      rare = { count = 1, label = "Nether Star" },
    }
    t.eq(stock.watch_from_contents(config, totals, 0.5), 2)
    t.eq(config.watches.cobble.limit, 320)
    t.eq(config.watches.rare.limit, 1, "limits are at least 1")
    t.eq(config.watches.existing.limit, 7, "existing watches are kept")
  end)

  t.it("watches and outputs are checked", function()
    local stock = t.fresh_import()("stock")
    t.ok(not stock.clean_watch({ limit = 0 }))
    t.ok(not stock.clean_watch({ limit = "x" }))
    t.ok(not stock.clean_watch({ limit = 5, outputs = { { target = "computer", side = "up" } } }))
    local watch = stock.clean_watch({ limit = 5.7, outputs = { { target = "computer", side = "top" } } })
    t.eq(watch.limit, 5)
  end)

  t.it("access is closed by default; domain admins are always admins", function()
    local stock = t.fresh_import()("stock")
    local config = stock.new_config({ "alice", "stock-admins" })
    config.access.viewers = { "kitchen-staff" }
    t.eq(stock.access_level(config, { name = "alice", groups = {} }), "admin")
    t.eq(stock.access_level(config, { name = "bob", groups = { "stock-admins" } }), "admin")
    t.eq(stock.access_level(config, { name = "carol", groups = { "kitchen-staff" } }), "viewer")
    t.eq(stock.access_level(config, { name = "dave", groups = { "domain-users" } }), nil)
    t.eq(stock.access_level(config, { name = "root", groups = { "domain-admins" } }), "admin")
    t.ok(not stock.is_computer_allowed(config, "board-pc"))
    config.access.computers = { "board-pc" }
    t.ok(stock.is_computer_allowed(config, "board-pc"))
  end)
end
