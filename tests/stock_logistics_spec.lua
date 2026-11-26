-- Item logistics: roles, sorting inputs into storage, requests to outputs.
return function(t)
  local STACK = 64

  -- A wired network of fake chests whose pushItems really moves items.
  local function fake_network(chests)
    local devices = {}
    local function push(from, to_name, slot, limit)
      local source, target = chests[from], chests[to_name]
      local stack = source.slots[slot]
      if not (stack and target) then
        return 0
      end
      local wanted = math.min(stack.count, limit or stack.count)
      local moved = 0
      -- Top up matching stacks first, then use empty slots (like a real chest).
      for target_slot = 1, target.size do
        local here = target.slots[target_slot]
        if moved >= wanted then
          break
        end
        if here and here.name == stack.name and here.count < STACK then
          local amount = math.min(STACK - here.count, wanted - moved)
          here.count = here.count + amount
          moved = moved + amount
        end
      end
      for target_slot = 1, target.size do
        if moved >= wanted then
          break
        end
        if not target.slots[target_slot] then
          local amount = math.min(STACK, wanted - moved)
          target.slots[target_slot] = { name = stack.name, count = amount }
          moved = moved + amount
        end
      end
      stack.count = stack.count - moved
      if stack.count == 0 then
        source.slots[slot] = nil
      end
      return moved
    end
    for name, chest in pairs(chests) do
      devices[name] = {
        types = { "inventory" },
        methods = {
          size = function() return chest.size end,
          list = function()
            local listed = {}
            for slot, stack in pairs(chest.slots) do
              listed[slot] = { name = stack.name, count = stack.count }
            end
            return listed
          end,
          getItemDetail = function(slot)
            local stack = chest.slots[slot]
            return stack and { name = stack.name, count = stack.count, displayName = stack.name }
          end,
          pushItems = function(to_name, slot, limit) return push(name, to_name, slot, limit) end,
        },
      }
    end
    return t.fake_peripherals(devices)
  end

  local function count_in(chest, item)
    local total = 0
    for _, stack in pairs(chest.slots) do
      if stack.name == item then
        total = total + stack.count
      end
    end
    return total
  end

  -- storage_a holds iron, storage_b is empty, pickup is an input, out an output.
  local function setup()
    local import = t.fresh_import()
    local chests = {
      storage_a = { size = 4, slots = { [1] = { name = "iron", count = 10 } } },
      storage_b = { size = 4, slots = {} },
      pickup = { size = 4, slots = {
        [1] = { name = "iron", count = 20 },
        [2] = { name = "dirt", count = 5 },
      } },
      out = { size = 2, slots = {} },
      furnace = { size = 3, slots = { [1] = { name = "coal", count = 8 } } },
    }
    local inventory = import("storage_sources/inventory")
    inventory.peripheral = fake_network(chests)
    local stock = import("stock")
    local config = stock.new_config({ "alice" })
    stock.set_storage(config, "pickup", "input")
    stock.set_storage(config, "out", "output")
    stock.set_storage(config, "furnace", "ignore")
    local function read()
      return import("stock_sources").read_all({ inventory }, function(handle)
        return stock.role_of(config, handle)
      end)
    end
    return chests, read, import("stock_logistics"), stock, config
  end

  t.it("only storage is counted; ignored blocks are left alone", function()
    local _, read = setup()
    local totals, blocks, _, inventories = read()
    t.eq(blocks, 2, "storage_a and storage_b")
    t.eq(totals.iron.count, 10, "items in the input chest are not counted yet")
    t.eq(totals.coal, nil, "the ignored furnace is not counted")
    t.eq(#inventories, 5, "every block is listed")
  end)

  t.it("inputs are emptied into storage, next to the same item first", function()
    local chests, read, logistics = setup()
    local _, _, _, inventories = read()
    local moves, failures = logistics.sort_inputs(inventories)
    t.ok(moves > 0)
    t.eq(#failures, 0)
    t.eq(next(chests.pickup.slots), nil, "the input chest is empty")
    t.eq(count_in(chests.storage_a, "iron"), 30, "iron joined the chest that had iron")
    t.eq(count_in(chests.storage_b, "iron"), 0)
    t.eq(count_in(chests.storage_a, "dirt") + count_in(chests.storage_b, "dirt"), 5)
    t.eq(count_in(chests.furnace, "coal"), 8, "ignored blocks are never touched")
  end)

  t.it("requests deliver to the output chest, as far as it has room", function()
    local chests, read, logistics = setup()
    local _, _, _, inventories = read()
    local result = assert(logistics.request(inventories, "iron", 6))
    t.eq(result.moved, 6)
    t.eq(result.output, "out")
    t.eq(count_in(chests.out, "iron"), 6)
    t.eq(count_in(chests.storage_a, "iron"), 4)

    chests.storage_a.slots[2] = { name = "dirt", count = 64 }
    chests.storage_a.slots[3] = { name = "dirt", count = 64 }
    chests.storage_a.slots[4] = { name = "dirt", count = 64 }
    _, _, _, inventories = read()
    local partial = assert(logistics.request(inventories, "dirt", 192))
    t.eq(partial.moved, 64, "the 2-slot output had room for one more stack")
  end)

  t.it("a request without an output chest says how to set one up", function()
    local _, read, logistics, stock, config = setup()
    stock.set_storage(config, "out", "storage")
    local _, _, _, inventories = read()
    local result, err = logistics.request(inventories, "iron", 1)
    t.ok(not result)
    t.ok(err:find("output"), err)
  end)

  t.it("roles and labels are stored sparingly and validated", function()
    local _, _, _, stock, config = setup()
    t.ok(not stock.set_storage(config, "storage_a", "bin"), "unknown roles are refused")
    t.ok(stock.set_storage(config, "storage_a", nil, "Ores"))
    t.eq(stock.storage_name(config, "storage_a"), "Ores")
    t.eq(stock.role_of(config, "storage_a"), "storage")
    t.ok(stock.set_storage(config, "storage_a", nil, ""))
    t.eq(config.storages.storage_a, nil, "nothing left to store")
    t.eq(stock.role_of(config, "new_chest"), "storage", "new chests count as storage")
  end)

  t.it("items and chests are found by id, label or part of it", function()
    local _, _, _, stock, config = setup()
    local totals = {
      ["minecraft:iron_ingot"] = { label = "Iron Ingot" },
      ["minecraft:iron_ore"] = { label = "Iron Ore" },
      ["mod:iron"] = { label = "Iron" },
    }
    t.eq(stock.find_item(totals, "iron"), "mod:iron", "an exact label wins")
    t.eq(stock.find_item(totals, "ingot"), "minecraft:iron_ingot")
    local found, err = stock.find_item(totals, "iron o")
    t.eq(found, "minecraft:iron_ore")
    t.eq(err, nil)
    local none, ambiguous = stock.find_item(totals, "minecraft:iron")
    t.ok(not none)
    t.ok(ambiguous:find("ambiguous"), ambiguous)
    stock.set_storage(config, "storage_b", nil, "Ores")
    t.eq(stock.find_storage(config, { "storage_a", "storage_b" }, "ores"), "storage_b")
  end)
end
