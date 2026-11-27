-- Logistics nodes: choosing the storage modem, the scoped view, rounds and reports,
-- the controller's calls, and lone mode (a hub over the node itself).
return function(t)
  local function wired_modem(remote)
    return {
      types = { "modem" },
      methods = {
        isWireless = function() return false end,
        getNamesRemote = function() return remote end,
        hasTypeRemote = function(_, kind) return kind == "inventory" end,
      },
    }
  end
  local WIRELESS = { types = { "modem" }, methods = { isWireless = function() return true end } }

  t.it("the storage modem is the wired one that sees chests", function()
    local node = t.fresh_import()("logistics_node")
    local sides = node.detect_sides(t.fake_peripherals({
      left = wired_modem({ "chest_1", "chest_2" }),
      right = WIRELESS,
    }))
    t.eq(sides.storage_side, "left")
    t.eq(sides.is_shared, nil)
    t.eq(sides.is_ambiguous, nil)

    local alone = node.detect_sides(t.fake_peripherals({ back = wired_modem({ "chest_1" }) }))
    t.eq(alone.storage_side, "back")
    t.eq(alone.is_shared, true, "the only modem carries rednet too: not closed")

    local two = node.detect_sides(t.fake_peripherals({
      left = wired_modem({ "chest_1" }),
      top = wired_modem({ "chest_2", "chest_3", "chest_4" }),
    }))
    t.eq(two.storage_side, "top", "the modem seeing the most chests")
    t.eq(two.is_ambiguous, true)

    local none = node.detect_sides(t.fake_peripherals({ right = WIRELESS }))
    t.eq(none.storage_side, nil)

    -- The main cable has computers (and ports, depots) on it: never the storage modem
    -- when another modem sees chests, and never closed when it is the only choice.
    local function main_cable(remote)
      local modem = wired_modem(remote)
      modem.methods.hasTypeRemote = function(name, kind)
        if kind == "computer" then
          return name:find("^computer") ~= nil
        end
        return kind == "inventory" and name:find("^chest") ~= nil
      end
      return modem
    end
    local busy = node.detect_sides(t.fake_peripherals({
      left = main_cable({ "computer_1", "chest_9", "chest_8", "chest_7" }),
      top = wired_modem({ "chest_1" }),
    }))
    t.eq(busy.storage_side, "top", "the small storage cable, not the busy main cable")
    local only_main = node.detect_sides(t.fake_peripherals({
      left = main_cable({ "computer_1", "chest_9" }),
      right = WIRELESS,
    }))
    t.eq(only_main.is_shared, true, "a cable with computers is never closed")
  end)

  -- A storage network (chest_a, out) on the left modem, a main network with
  -- chest_b, and a barrel placed against the computer.
  local function fake_world()
    local chests = {
      chest_a = { slots = { [1] = { name = "iron", count = 30 } } },
      out = { slots = {} },
      chest_b = { slots = { [1] = { name = "gold", count = 5 } } },
      top = { slots = { [1] = { name = "dirt", count = 3 } } },
    }
    local devices = { left = wired_modem({ "chest_a", "out" }), right = wired_modem({ "chest_b" }) }
    for name, chest in pairs(chests) do
      devices[name] = {
        types = { "minecraft:chest", "inventory" },
        methods = {
          size = function() return 27 end,
          list = function()
            local listed = {}
            for slot, stack in pairs(chest.slots) do
              listed[slot] = { name = stack.name, count = stack.count }
            end
            return listed
          end,
          getItemDetail = function(slot)
            local stack = chest.slots[slot]
            return stack and { displayName = stack.name:upper() }
          end,
          pushItems = function(to, slot, limit)
            local stack = chest.slots[slot]
            local amount = math.min(stack.count, limit or stack.count)
            local target = chests[to].slots
            target[#target + 1] = { name = stack.name, count = amount }
            stack.count = stack.count - amount
            if stack.count == 0 then
              chest.slots[slot] = nil
            end
            return amount
          end,
        },
      }
    end
    return chests, t.fake_peripherals(devices)
  end

  t.it("the scoped view only sees the storage network and attached blocks", function()
    local _, api = fake_world()
    local scope = t.fresh_import()("logistics_scope").new("left", api)
    local names = table.concat(scope.getNames(), ",")
    t.eq(names, "chest_a,out,top")
    t.eq(scope.wrap("chest_b"), nil, "chests on the main network are out of reach")
    t.eq(scope.hasType("chest_b", "inventory"), nil)
    t.ok(scope.wrap("chest_a"))
    t.eq(t.fresh_import()("logistics_scope").new(nil, api), api, "no storage modem: all")
  end)

  local function new_node(import, api)
    local inventory = import("storage_sources/inventory")
    inventory.peripheral = import("logistics_scope").new("left", api)
    local logistics = import("logistics")
    local config = logistics.normalise_node({})
    logistics.set_storage(config, "out", "output")
    return import("logistics_node").new({
      config = config,
      save = function() return true end,
      sources = { inventory },
    })
  end

  t.it("a round counts the storage network and the report hands moves over once", function()
    local import = t.fresh_import()
    local chests, api = fake_world()
    local node = new_node(import, api)
    node.round()
    local report = node.report()
    t.eq(report.totals.iron.count, 30)
    t.eq(report.totals.dirt.count, 3, "the barrel against the computer counts")
    t.eq(report.totals.gold, nil, "the main network's chest does not")
    t.eq(#report.blocks, 3)
    local result = assert(node.request("iron", 10))
    t.eq(result.moved, 10)
    t.eq(chests.out.slots[1].count, 10)
    t.eq(node.totals.iron.count, 20, "counts drop at once")
    t.eq(#node.report().moves, 1)
    t.eq(#node.report().moves, 0, "moves go out once")
  end)

  t.it("in a domain only joined computers may call a node", function()
    local import = t.fresh_import()
    local _, api = fake_world()
    local node = new_node(import, api)
    node.round()
    local rpc = import("rpc")
    rpc.set_computer_validator(function(token)
      return token == "controller-token" and { hostname = "controller" } or nil
    end)
    local joined = node.handlers(nil, function() return true end)
    local args = { item = "iron", count = 1 }
    t.ok(not joined.request({ sender = 4 }, args), "no computer token")
    t.ok(joined.request({ sender = 4, computer_token = "controller-token" }, args))
    local open = node.handlers(nil, function() return false end)
    t.ok(open.request({ sender = 4 }, args), "standalone: open")
    t.ok(not open.export_levels({ sender = 4 }), "no levels to hand over")
  end)

  t.it("lone mode: a hub over the node itself requests and watches", function()
    local import = t.fresh_import()
    local chests, api = fake_world()
    local node = new_node(import, api)
    local alarms = import("logistics_alarms")
    alarms.env.broadcast = function() end
    local hub = import("logistics_hub").new({
      config = { watches = { iron = { label = "Iron", limit = 50, outputs = {} } } },
      save = function() return true end,
      hostname = "node-1",
    })
    node.round()
    local report = node.report()
    report.node = "node-1"
    hub.update("node-1", report, node.proxy())
    t.eq(hub.states.iron.is_low, true, "30 of 50")
    local handlers = import("logistics_handlers").new(hub)
    local result = assert(handlers.request({ local_admin = true }, { item = "iron", count = 5 }))
    t.eq(result.moved, 5)
    t.eq(result.node, "node-1")
    t.eq(chests.out.slots[1].count, 5)
    t.eq(hub.totals().iron.count, 25, "counted down once, not twice")
  end)

  t.it("two players can find chests at once; the node's own moves are no answer", function()
    local import = t.fresh_import()
    local chests, api = fake_world()
    local node = new_node(import, api)
    node.round()
    node.find_start("alice")
    node.find_start("bob")
    chests.top.slots[2] = { name = "stick", count = 1 } -- alice drops a stick in
    node.request("iron", 3) -- the node moves iron from chest_a to out meanwhile
    local found = node.find_finish("alice")
    t.eq(#found, 1)
    t.eq(found[1].handle, "top")
    t.ok(node.sort_paused_until > 0, "bob is still searching: sorting stays paused")
    node.find_finish("bob")
    t.eq(node.sort_paused_until, 0)
  end)

  t.it("the block list goes out only when it changed (counts every round)", function()
    local import = t.fresh_import()
    local _, api = fake_world()
    local node = new_node(import, api)
    node.round()
    t.ok(node.report().blocks, "the first report has the list")
    node.round()
    local second = node.report()
    t.eq(second.blocks, nil, "unchanged: left out")
    t.ok(second.totals.iron, "counts always go")
    node.set_storage({ storage = "chest_a", label = "Ores" })
    node.round()
    t.ok(node.report().blocks, "changed: sent again")
    local hub = import("logistics_hub").new({ config = {}, save = function() return true end })
    hub.update("n", { totals = {}, blocks = { { handle = "a", role = "storage" } } }, {})
    hub.update("n", { totals = {} }, {})
    t.eq(#hub.list_storages(), 1, "the hub keeps the last list")
  end)

end
