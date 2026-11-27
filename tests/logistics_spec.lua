-- Logistics logic: limits, recovery margin, outputs, filling from storage, old configs.
return function(t)
  local function config_with(watches)
    local logistics = t.fresh_import()("logistics")
    local config = logistics.normalise({})
    config.watches = watches
    return logistics, config
  end

  t.it("items go low below their limit and recover above a margin", function()
    local iron = { ["minecraft:iron_ingot"] = { label = "Iron", limit = 100 } }
    local logistics, config = config_with(iron)
    local function at(count, previous)
      return logistics.evaluate(config, { ["minecraft:iron_ingot"] = { count = count } }, previous)
    end
    local states = at(120)
    local changes
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
    local gold = { ["minecraft:gold_ingot"] = { label = "Gold", limit = 1 } }
    local logistics, config = config_with(gold)
    local states = logistics.evaluate(config, {})
    t.eq(states["minecraft:gold_ingot"].count, 0)
    t.ok(states["minecraft:gold_ingot"].is_low)
  end)

  t.it("an item unwatched while low recovers once", function()
    local logistics, config = config_with({ gold = { label = "Gold", limit = 10 } })
    local states = logistics.evaluate(config, { gold = { count = 2 } })
    t.ok(states.gold.is_low)
    config.watches.gold = nil
    local changes
    states, changes = logistics.evaluate(config, { gold = { count = 2 } }, states)
    t.eq(states.gold, nil, "no longer shown")
    t.eq(changes.recovered[1], "gold")
    t.eq(changes.cleared.gold.is_low, false)
    t.eq(changes.cleared.gold.label, "Gold")
    local _, later = logistics.evaluate(config, { gold = { count = 2 } }, states)
    t.eq(#later.recovered, 0, "only once")
  end)

  t.it("an output is on while any item mapped to it is low", function()
    local lamp = { target = "redstone_relay_0", side = "top" }
    local logistics, config = config_with({
      a = { label = "A", limit = 10, outputs = { lamp } },
      b = { label = "B", limit = 10, outputs = { lamp } },
    })
    config.any_low_outputs = { { target = "computer", side = "back" } }
    local states = logistics.evaluate(config, { a = { count = 50 }, b = { count = 50 } })
    local outputs = logistics.output_states(config, states)
    t.ok(not outputs["redstone_relay_0|top"].is_on)
    t.ok(not outputs["computer|back"].is_on)
    states = logistics.evaluate(config, { a = { count = 50 }, b = { count = 1 } })
    outputs = logistics.output_states(config, states)
    t.ok(outputs["redstone_relay_0|top"].is_on)
    t.ok(outputs["computer|back"].is_on, "the any-low output follows any item")
  end)

  t.it("the watch list can be filled from storage contents", function()
    local logistics, config = config_with({ existing = { label = "Kept", limit = 7 } })
    local totals = {
      existing = { count = 100, label = "Kept" },
      cobble = { count = 640, label = "Cobblestone" },
      rare = { count = 1, label = "Nether Star" },
    }
    t.eq(logistics.watch_from_contents(config, totals, 0.5), 2)
    t.eq(config.watches.cobble.limit, 320)
    t.eq(config.watches.rare.limit, 1, "limits are at least 1")
    t.eq(config.watches.existing.limit, 7, "existing watches are kept")
  end)

  t.it("watches and outputs are checked", function()
    local logistics = t.fresh_import()("logistics")
    t.ok(not logistics.clean_watch({ limit = 0 }))
    t.ok(not logistics.clean_watch({ limit = "x" }))
    local bad_side = { { target = "computer", side = "up" } }
    t.ok(not logistics.clean_watch({ limit = 5, outputs = bad_side }))
    local outputs = { { target = "computer", side = "top" } }
    local watch = logistics.clean_watch({ limit = 5.7, outputs = outputs })
    t.eq(watch.limit, 5)
  end)

  t.it("an old storage-monitor config splits into node and levels", function()
    local logistics = t.fresh_import()("logistics")
    local old = {
      poll_seconds = 20,
      name = "kitchen",
      chime = false,
      watches = { iron = { label = "Iron", limit = 5, outputs = {} } },
      access = { admins = { "alice" } },
      storages = { ["minecraft:chest_1"] = { role = "input" } },
    }
    local node, levels = logistics.split_old_config(old)
    t.eq(node.poll_seconds, 20)
    t.eq(node.storages["minecraft:chest_1"].role, "input")
    t.eq(node.watches, nil, "levels stay out of the node config")
    t.eq(levels.watches.iron.limit, 5)
    t.eq(levels.name, "kitchen")
    t.eq(levels.chime, false)
    t.eq(levels.access, nil, "access lists are gone (roles replace them)")
  end)

  t.it("a refill target keeps an item low until it is refilled (farms)", function()
    local logistics, config = config_with({
      iron = { label = "Iron", limit = 200, refill_to = 1000 },
    })
    local function at(count, previous)
      return logistics.evaluate(config, { iron = { count = count } }, previous)
    end
    local states = at(150)
    t.ok(states.iron.is_low, "below the limit: the farm starts")
    states = at(600, states)
    t.ok(states.iron.is_low, "still refilling")
    local changes
    states, changes = at(1000, states)
    t.ok(not states.iron.is_low, "refilled: the farm stops")
    t.eq(changes.recovered[1], "iron")
    states = at(500, states)
    t.ok(not states.iron.is_low, "does not restart above the limit")
    t.ok(not logistics.clean_watch({ limit = 200, refill_to = 100 }),
      "refill must be above the limit")
  end)

  t.it("reactions on another computer follow the item state", function()
    local logistics = t.fresh_import()("logistics")
    local reactions = {
      { item = "iron", target = "computer", side = "back" },
      { item = "gold", target = "computer", side = "back" },
      { item = "coal", target = "redstone_relay_1", side = "top" },
    }
    local outputs = logistics.reaction_outputs(reactions, { iron = true, coal = false })
    t.ok(outputs["computer|back"].is_on, "on while any of its items is low")
    t.ok(not outputs["redstone_relay_1|top"].is_on)
    outputs = logistics.reaction_outputs(reactions, {})
    t.ok(not outputs["computer|back"].is_on, "unknown state counts as not low")
  end)

  t.it("the alert history is newest first with only the latest per item current", function()
    local logistics = config_with({})
    local history = logistics.alert_history({
      { server = "s", item = "copper", is_low = true },
      { server = "s", item = "iron", is_low = true },
      { server = "s", item = "copper", is_low = false },
    })
    t.eq(history[1].item, "copper")
    t.eq(history[1].is_low, false)
    t.ok(history[1].is_current, "the newest copper alert is current")
    t.ok(history[2].is_current, "iron has only one alert")
    t.eq(history[3].is_low, true)
    t.ok(not history[3].is_current, "the old LOW is superseded")
  end)

  t.it("controller names are checked and lower-cased", function()
    local logistics = config_with({})
    t.eq(logistics.check_name("Farm"), "farm")
    t.ok(not logistics.check_name(""), "empty")
    t.ok(not logistics.check_name("farm.home"), "no dots")
    t.ok(not logistics.check_name(string.rep("a", logistics.MAX_NAME_LENGTH + 1)), "too long")
    t.eq(#("logistics-" .. string.rep("a", logistics.MAX_NAME_LENGTH)), 32)
  end)
end
