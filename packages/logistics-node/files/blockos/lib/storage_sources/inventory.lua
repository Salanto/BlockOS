--- Storage source: chests and any other block with CC's generic inventory API
-- (barrels, Storage Drawers, Sophisticated Storage, Create Item Vaults, ...),
-- attached directly or through wired modems.
-- @module storage_sources.inventory

local inventory = {}

inventory.kind = "inventory"

--- The peripheral API to use (tests replace it with a stub).
inventory.peripheral = peripheral

-- Item labels never change, so each is looked up only once. Neither do sizes.
local labels = {}
local sizes = {}

function inventory.describe()
  return "Chests and other inventories"
end

-- Words in a block's peripheral types (or name) that mean "a plain container".
-- Anything else with an inventory (furnaces, machines, crafters, trash cans)
-- must not have items sorted into it unless someone says so.
local CONTAINER_WORDS = { "chest", "barrel", "shulker", "drawer", "vault", "crate", "storage" }

local function looks_like_container(text)
  local lowered = tostring(text):lower()
  for _, word in ipairs(CONTAINER_WORDS) do
    if lowered:find(word, 1, true) then
      return true
    end
  end
  return false
end

--- The role a block gets before anyone sets one: containers are storage,
-- everything else is ignored (so items are never sorted into a furnace).
-- @tparam string name Peripheral name.
-- @treturn string "storage" or "ignore"
function inventory.default_role(name)
  local types = { inventory.peripheral.getType(name) }
  types[#types + 1] = name
  for _, text in ipairs(types) do
    if looks_like_container(text) then
      return "storage"
    end
  end
  return "ignore"
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

--- @tparam string name
-- @treturn number How many slots the inventory has (asked once per block).
function inventory.size(name)
  if not sizes[name] then
    sizes[name] = inventory.peripheral.wrap(name).size()
  end
  return sizes[name]
end

local function fill_of(name, slots)
  local used = 0
  for _ in pairs(slots) do
    used = used + 1
  end
  local ok, size = pcall(inventory.size, name)
  return { used = used, size = ok and size or nil }
end

--- Add up the items in one inventory.
-- @tparam string name Peripheral name.
-- @treturn table [item] = { count, label }
-- @treturn table fill: { used, size } slots, for fill bars without extra calls
function inventory.read(name)
  local block = inventory.peripheral.wrap(name)
  local items = {}
  local slots = block.list()
  for slot, stack in pairs(slots) do
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
  return items, fill_of(name, slots)
end

--- How full a block is, without adding up items (for inputs and outputs).
-- @tparam string name
-- @treturn table { used, size }
function inventory.fill(name)
  return fill_of(name, inventory.peripheral.wrap(name).list())
end

-- Logistics (optional source functions; sources without them are only counted).

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
-- @tparam[opt] number to_slot Slot in `to` (default: wherever it fits).
-- @treturn number How many items moved.
function inventory.push(from, to, slot, limit, to_slot)
  return inventory.peripheral.wrap(from).pushItems(to, slot, limit, to_slot)
end

return inventory
