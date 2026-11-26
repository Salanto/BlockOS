--- Storage source: chests and any other block with CC's generic inventory API
-- (barrels, Storage Drawers, Sophisticated Storage, Create Item Vaults, ...),
-- attached directly or through wired modems.
-- @module storage_sources.inventory

local inventory = {}

inventory.kind = "inventory"

--- The peripheral API to use (tests replace it with a stub).
inventory.peripheral = peripheral

-- Item labels never change, so each is looked up only once.
local labels = {}

function inventory.describe()
  return "Chests and other inventories"
end

--- @treturn {string...} Names of every attached inventory.
function inventory.detect()
  local found = {}
  for _, name in ipairs(inventory.peripheral.getNames()) do
    if inventory.peripheral.hasType(name, "inventory") then
      found[#found + 1] = name
    end
  end
  table.sort(found)
  return found
end

--- Add up the items in one inventory.
-- @tparam string name Peripheral name.
-- @treturn table [item] = { count, label }
function inventory.read(name)
  local block = inventory.peripheral.wrap(name)
  local items = {}
  for slot, stack in pairs(block.list()) do
    local entry = items[stack.name]
    if not entry then
      if not labels[stack.name] then
        local detail = block.getItemDetail(slot)
        labels[stack.name] = detail and detail.displayName or stack.name
      end
      entry = { count = 0, label = labels[stack.name] }
      items[stack.name] = entry
    end
    entry.count = entry.count + stack.count
  end
  return items
end

-- Logistics (optional source functions; sources without them are only counted).

--- @tparam string name
-- @treturn number How many slots the inventory has.
function inventory.size(name)
  return inventory.peripheral.wrap(name).size()
end

--- @tparam string name
-- @treturn table [slot] = { name, count }
function inventory.list(name)
  return inventory.peripheral.wrap(name).list()
end

--- Move items from one slot to another inventory on the same wired network.
-- @tparam string from Peripheral name.
-- @tparam string to Peripheral name.
-- @tparam number slot Slot in `from`.
-- @tparam[opt] number limit At most this many items.
-- @treturn number How many items moved.
function inventory.push(from, to, slot, limit)
  return inventory.peripheral.wrap(from).pushItems(to, slot, limit)
end

return inventory
