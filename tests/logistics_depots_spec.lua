-- Depots: output chests with a position; requests near a place go to the nearest one
-- that can deliver; positions are set and cleared; logistics_api for programs.
return function(t)
  local function proxy(calls, name)
    return {
      request = function(item, count, output)
        calls[#calls + 1] = { node = name, item = item, count = count, output = output }
        return { moved = count, output = output }
      end,
      set_storage = function(change)
        calls[#calls + 1] = { node = name, change = change }
        return { storage = change.storage }
      end,
    }
  end

  -- Two nodes far apart, each with a depot. "west" has 5 coal, "east" has 100.
  local function new_hub()
    local import = t.fresh_import()
    import("roles").env.is_joined = function() return false end
    local alarms = import("logistics_alarms")
    alarms.env.broadcast = function() end
    local hub = import("logistics_hub").new({ config = {}, save = function() return true end })
    local calls = {}
    hub.update("west", {
      totals = { coal = { count = 5, label = "Coal" } },
      blocks = {
        { handle = "w_out", label = "West depot", role = "output",
          pos = { x = 0, y = 64, z = 0 } },
        { handle = "w_box", label = "West box", role = "storage" },
      },
    }, proxy(calls, "west"))
    hub.update("east", {
      totals = { coal = { count = 100, label = "Coal" }, iron = { count = 3, label = "Iron" } },
      blocks = {
        { handle = "e_out", label = "East depot", role = "output",
          pos = { x = 500, y = 64, z = 0 } },
        { handle = "e_plain", label = "Plain output", role = "output" },
      },
    }, proxy(calls, "east"))
    return hub, calls, import
  end

  t.it("depots are outputs with a position, nearest first", function()
    local hub = new_hub()
    local depots = hub.depots({ x = 490, y = 64, z = 0 })
    t.eq(#depots, 2, "the plain output without a position is no depot")
    t.eq(depots[1].label, "East depot")
    t.eq(math.floor(depots[1].distance), 10)
    t.eq(#hub.depots(), 2)
  end)

  t.it("a request near a place goes to the nearest depot that has enough", function()
    local hub, calls = new_hub()
    local near_west = { x = 10, y = 64, z = 0 }
    local result = assert(hub.request("coal", 4, nil, nil, near_west))
    t.eq(result.node, "west", "west has 5: enough for 4")
    t.eq(result.output_label, "West depot")
    t.eq(result.pos.x, 0)
    result = assert(hub.request("coal", 20, nil, nil, near_west))
    t.eq(result.node, "east", "west has too few, so the far depot delivers")
    t.eq(calls[#calls].output, "e_out")
    result = assert(hub.request("iron", 50, nil, nil, near_west))
    t.eq(result.node, "east", "nobody has 50: the nearest with some")
    local _, err = hub.request("diamond", 1, nil, nil, near_west)
    t.ok(err, "nobody has any")
  end)

  t.it("handlers take near, list depots and set positions", function()
    local hub, calls, import = new_hub()
    local handlers = import("logistics_handlers").new(hub)
    local ctx = { sender = 3 }
    local result = assert(handlers.request(ctx, { item = "coal", count = 2,
      near = { x = 499, y = 60, z = 1 } }))
    t.eq(result.node, "east")
    t.ok(not handlers.request(ctx, { item = "coal", count = 2, near = { x = 1 } }),
      "a position needs x, y and z")
    t.eq(handlers.depots(ctx, { near = { x = 0, y = 64, z = 0 } })[1].label, "West depot")

    t.ok(handlers.set_storage(ctx, { storage = "plain output", pos = { x = 1.4, y = 2, z = 3 } }))
    t.eq(calls[#calls].change.pos.x, 1.4)
    t.eq(#hub.depots(), 3, "the plain output is a depot now")
    t.ok(handlers.set_storage(ctx, { storage = "plain output", clear_pos = true }))
    t.eq(#hub.depots(), 2)
  end)

  t.it("a node stores positions, rounded, and clears them", function()
    local import = t.fresh_import()
    local logistics = import("logistics")
    local config = logistics.normalise_node({})
    local node = import("logistics_node").new({
      config = config,
      save = function() return true end,
      sources = {},
    })
    config.storages.out = { role = "output" }
    t.ok(node.set_storage({ storage = "out", pos = { x = 1.6, y = 64, z = -2.4 } }))
    t.eq(config.storages.out.pos.x, 2)
    t.eq(config.storages.out.pos.z, -2)
    t.eq(config.storages.out.role, "output", "the role stays")
    t.ok(not node.set_storage({ storage = "out", pos = { x = "a" } }))
    t.ok(node.set_storage({ storage = "out", clear_pos = true }))
    t.eq(config.storages.out.pos, nil)
  end)

  t.it("programs request near their own position with logistics_api", function()
    local hub, _, import = new_hub()
    _G.blockos = {
      logistics_hub = { hub = hub, handlers = import("logistics_handlers").new(hub),
        config = hub.config },
    }
    local api = import("logistics_api")
    api.locate = function() return { x = 3, y = 64, z = 0 } end
    local result = assert(api.request("coal", 3, { here = true }))
    t.eq(result.node, "west")
    t.eq(result.output_label, "West depot")
    t.eq(api.depots({ here = true })[1].node, "west")
    t.eq(api.count("coal"), 102, "105 minus the 3 just requested")
    t.eq(api.count("diamond"), 0)
    api.locate = function() return nil end
    local _, err = api.request("coal", 1, { here = true })
    t.ok(err:find("GPS"), err)
  end)
end
