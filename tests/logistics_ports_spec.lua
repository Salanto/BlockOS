-- Ports: automatic pairing by a marker item, the three-step crossing between nodes,
-- and leftovers sorted back into storage.
return function(t)
  -- Physical chests, seen under different names on different wired networks.
  local function new_world()
    local chests = {
      a_store = { { name = "iron", count = 50 } },
      a_port = {},
      b_store = { { name = "dirt", count = 8 } },
      b_port = {},
      b_out = {},
      farm = {}, -- a farm's chest on the main cable, nobody's port
    }
    -- name -> chest, per network
    local networks = {
      a = { chest_1 = "a_store", chest_2 = "a_port" },
      b = { chest_1 = "b_store", chest_2 = "b_port", chest_3 = "b_out" },
      main = { chest_10 = "a_port", chest_11 = "b_port", chest_12 = "farm" },
    }
    local function api_for(network)
      local names = networks[network]
      local devices = {}
      local remote = {}
      for name, chest_name in pairs(names) do
        remote[#remote + 1] = name
        local chest = chests[chest_name]
        devices[name] = {
          types = { "minecraft:chest", "inventory" },
          methods = {
            size = function() return 27 end,
            list = function()
              local listed = {}
              for slot, stack in pairs(chest) do
                listed[slot] = { name = stack.name, count = stack.count }
              end
              return listed
            end,
            getItemDetail = function(slot)
              return chest[slot] and { displayName = chest[slot].name }
            end,
            pushItems = function(to, slot, limit)
              local stack = chest[slot]
              local target = chests[names[to]]
              if not (stack and target) then
                return 0
              end
              local amount = math.min(stack.count, limit or stack.count)
              local free = 1
              while target[free] do
                free = free + 1
              end
              target[free] = { name = stack.name, count = amount }
              stack.count = stack.count - amount
              if stack.count == 0 then
                chest[slot] = nil
              end
              return amount
            end,
          },
        }
      end
      table.sort(remote)
      devices.left = {
        types = { "modem" },
        methods = {
          isWireless = function() return false end,
          getNamesRemote = function() return remote end,
          hasTypeRemote = function() return true end,
        },
      }
      return t.fake_peripherals(devices)
    end
    return chests, api_for
  end

  local function count(chest, item)
    local total = 0
    for _, stack in pairs(chest) do
      if stack.name == item then
        total = total + stack.count
      end
    end
    return total
  end

  -- One node per fresh import (each has its own inventory source), roles set.
  local function new_node(api, roles, clock)
    local import = t.fresh_import()
    local inventory = import("storage_sources/inventory")
    inventory.peripheral = import("logistics_scope").new("left", api)
    local node_module = import("logistics_node")
    node_module.env.clock = clock
    local config = import("logistics").normalise_node({})
    for handle, role in pairs(roles) do
      config.storages[handle] = { role = role }
    end
    return node_module.new({ config = config, save = function() return true end,
      sources = { inventory } })
  end

  local function setup()
    local chests, api_for = new_world()
    local now = 0
    local function clock() return now end
    local node_a = new_node(api_for("a"), { chest_2 = "port" }, clock)
    local node_b = new_node(api_for("b"), { chest_2 = "port", chest_3 = "output" }, clock)
    local import = t.fresh_import()
    import("logistics_alarms").env.broadcast = function() end
    local ports_module = import("logistics_ports")
    ports_module.env.peripheral = api_for("main")
    ports_module.env.clock = clock
    local config = {}
    local ports = ports_module.new(config, function() return true end)
    local hub = import("logistics_hub").new({
      config = {},
      save = function() return true end,
      transfer = ports.transfer,
      port_status = ports.status,
    })
    local function report()
      node_a.round()
      node_b.round()
      hub.update("a", node_a.report(), node_a.proxy())
      hub.update("b", node_b.report(), node_b.proxy())
    end
    report()
    return {
      chests = chests, hub = hub, ports = ports, config = config, report = report,
      node_a = node_a, node_b = node_b, advance = function(seconds) now = now + seconds end,
    }
  end

  t.it("a port pairs itself by a marker item on the main cable", function()
    local w = setup()
    t.eq(w.hub.list_storages()[1].port, nil, "a's storage chest is no port")
    local wanted = w.ports.check("a", w.hub.nodes.a.report.blocks)
    t.eq(wanted[1], "chest_2")
    t.eq(w.ports.pair("a", "chest_2", w.node_a.proxy()), "chest_10")
    t.eq(w.config.ports["a/chest_2"], "chest_10")
    t.eq(count(w.chests.a_port, "iron"), 1, "the marker waits in the port")
    t.eq(#w.ports.check("a", w.hub.nodes.a.report.blocks), 0, "paired: nothing to do")
    t.eq(w.ports.pair("b", "chest_2", w.node_b.proxy()), "chest_11")
    local statuses = {}
    for _, row in ipairs(w.hub.list_storages()) do
      if row.role == "port" then
        statuses[#statuses + 1] = row.port
      end
    end
    t.eq(table.concat(statuses, ","), "paired,paired")
  end)

  t.it("items cross from one node to another's output through the ports", function()
    local w = setup()
    w.ports.pair("a", "chest_2", w.node_a.proxy())
    w.ports.pair("b", "chest_2", w.node_b.proxy())
    w.report()
    local result = assert(w.hub.request("iron", 10))
    t.eq(result.moved, 10)
    t.eq(result.node, "b", "b has the only output")
    t.eq(result.from, "a")
    t.eq(result.output, "chest_3")
    t.eq(count(w.chests.b_out, "iron"), 10)
    t.eq(count(w.chests.a_store, "iron"), 39, "50 - 1 marker - 10")
    t.eq(w.hub.totals().iron.count, 39, "counts drop at once")
    local crossing = w.hub.moves[#w.hub.moves]
    t.ok(crossing.crossing, "the crossing is in the move log (for the wall)")
    t.eq(crossing.from_node, "a")
    t.eq(crossing.node, "b")
    t.eq(crossing.count, 10)
  end)

  t.it("leftovers in a port are sorted back once the hold is over", function()
    local w = setup()
    w.ports.pair("a", "chest_2", w.node_a.proxy())
    t.eq(count(w.chests.a_port, "iron"), 1)
    w.node_a.round()
    t.eq(count(w.chests.a_port, "iron"), 1, "held while a crossing may be under way")
    w.advance(20)
    w.node_a.round()
    t.eq(count(w.chests.a_port, "iron"), 0)
    t.eq(count(w.chests.a_store, "iron"), 50, "back in storage")
  end)

  t.it("without a paired port the request says what to build", function()
    local w = setup()
    local _, err = w.hub.request("iron", 5)
    t.ok(err and err:find("port"), tostring(err))
  end)

  t.it("a block that stops being a port loses its pairing", function()
    local w = setup()
    w.ports.pair("a", "chest_2", w.node_a.proxy())
    w.node_a.set_storage({ storage = "chest_2", role = "storage" })
    w.report()
    w.ports.check("a", w.hub.nodes.a.report.blocks)
    t.eq(w.config.ports["a/chest_2"], nil)
  end)

  t.it("each crossing holds the ports until its own last step", function()
    local w = setup()
    w.node_b.port_hold(nil, "first")
    w.node_b.port_hold(nil, "second")
    w.node_b.from_port("chest_2", "iron", 1, nil, "first")
    t.ok(w.node_b.ports_held(), "the second crossing still holds them")
    w.node_b.from_port("chest_2", "iron", 1, nil, "second")
    t.ok(not w.node_b.ports_held())
    w.node_b.port_hold(nil, "stuck")
    w.advance(20)
    t.ok(not w.node_b.ports_held(), "a hold that never finished runs out")
  end)

  t.it("pairing looks for the marker item itself, not any chest that filled", function()
    local w = setup()
    local proxy = w.node_a.proxy()
    local marker = proxy.push_marker
    proxy.push_marker = function(port)
      w.chests.farm[1] = { name = "wheat", count = 9 } -- the farm fills meanwhile
      return marker(port)
    end
    t.eq(w.ports.pair("a", "chest_2", proxy), "chest_10")
    proxy.push_marker = function(port)
      w.chests.farm[2] = { name = "iron", count = 1 } -- the same item: can't tell
      return marker(port)
    end
    w.ports.unpair("a", "chest_2")
    local found, err = w.ports.pair("a", "chest_2", proxy)
    t.eq(found, nil)
    t.ok(err:find("candidates"), err)
  end)

  t.it("a chest already paired to one port is never paired to another", function()
    local w = setup()
    t.eq(w.ports.pair("a", "chest_2", w.node_a.proxy()), "chest_10")
    t.eq(w.ports.pair("b", "chest_2", w.node_b.proxy()), "chest_11")
    local taken = {}
    for _, main in pairs(w.config.ports) do
      t.ok(not taken[main], "each chest pairs once")
      taken[main] = true
    end
  end)

  t.it("a crossing that never reaches the node's side drops the wrong pairing", function()
    local w = setup()
    w.ports.pair("a", "chest_2", w.node_a.proxy())
    w.config.ports["b/chest_2"] = "chest_12" -- wrongly paired to the farm chest
    w.report()
    local _, err = w.hub.request("iron", 5)
    t.ok(err and err:find("wrong chest"), tostring(err))
    t.eq(w.config.ports["b/chest_2"], nil, "paired again on the next report")
    t.eq(count(w.chests.farm, "iron"), 5, "the log says where the items went")
  end)
end
