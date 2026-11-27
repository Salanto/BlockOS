--- Item logistics: empty input chests into storage and deliver requests to
-- output chests.
--
-- Works on the inventory list from logistics_sources.read_all. Items only move
-- between blocks of the same source, using the source's optional `list` and
-- `push` (for chests: CC's pushItems, which needs both blocks on the node's
-- storage network). Every peripheral call takes a game tick, so the
-- work per round is capped.
-- @module logistics_sorting

local logistics_sorting = {}

--- At most this many moves per sorting round (each takes about a tick).
logistics_sorting.MAX_MOVES = 32

local function can_move(source)
  return type(source.list) == "function" and type(source.push) == "function"
end

-- Storage blocks of the same source, the ones already holding the item first
-- (to top up stacks there), then the rest in their usual order.
local function storage_targets(inventories, source, item)
  local holding, others = {}, {}
  for _, inventory in ipairs(inventories) do
    if inventory.role == "storage" and inventory.source == source then
      if inventory.items and inventory.items[item] then
        holding[#holding + 1] = inventory
      else
        others[#others + 1] = inventory
      end
    end
  end
  for _, inventory in ipairs(others) do
    holding[#holding + 1] = inventory
  end
  return holding
end

-- Move one input slot into storage. Returns moves made and the first error.
local function sort_slot(inventories, input, slot, stack, moves_left, on_move)
  local remaining = stack.count
  local moves = 0
  for _, target in ipairs(storage_targets(inventories, input.source, stack.name)) do
    if remaining <= 0 or moves >= moves_left then
      break
    end
    local ok, moved = pcall(input.source.push, input.handle, target.handle, slot)
    moves = moves + 1
    if not ok then
      return moves, tostring(moved)
    end
    remaining = remaining - (moved or 0)
    if (moved or 0) > 0 and on_move then
      on_move(input.handle, target.handle, stack.name, moved)
    end
  end
  return moves, nil
end

--- Empty every input block into storage (one capped round).
-- @tparam {table...} inventories From logistics_sources.read_all.
-- @tparam[opt] function on_move function(from, to, item, count), per move made
-- @treturn number Moves made.
-- @treturn {table...} failures: { handle, error }, for the log
function logistics_sorting.sort_inputs(inventories, on_move)
  local moves = 0
  local failures = {}
  for _, input in ipairs(inventories) do
    if input.role == "input" and can_move(input.source) then
      local ok, slots = pcall(input.source.list, input.handle)
      if not ok then
        failures[#failures + 1] = { handle = tostring(input.handle), error = tostring(slots) }
      else
        for slot, stack in pairs(slots) do
          if moves >= logistics_sorting.MAX_MOVES then
            return moves, failures
          end
          local made, err = sort_slot(inventories, input, slot, stack,
            logistics_sorting.MAX_MOVES - moves, on_move)
          moves = moves + made
          if err then
            failures[#failures + 1] = { handle = tostring(input.handle), error = err }
            break
          end
        end
      end
    end
  end
  return moves, failures
end

local function find_output(inventories, handle)
  for _, inventory in ipairs(inventories) do
    local is_wanted = handle == nil or inventory.handle == handle
    if inventory.role == "output" and is_wanted and can_move(inventory.source) then
      return inventory
    end
  end
  return nil
end

-- Take up to `wanted` of an item out of one storage block into the output.
local function take_from(storage, output, item, wanted, on_move)
  local ok, slots = pcall(storage.source.list, storage.handle)
  if not ok then
    return 0
  end
  local moved_total = 0
  for slot, stack in pairs(slots) do
    if moved_total >= wanted then
      break
    end
    if stack.name == item then
      local pushed, moved = pcall(storage.source.push, storage.handle, output.handle, slot,
        wanted - moved_total)
      if not pushed or (moved or 0) == 0 then
        -- The output is full (or gone): no point in trying more slots.
        return moved_total, true
      end
      moved_total = moved_total + moved
      if on_move then
        on_move(storage.handle, output.handle, item, moved)
      end
    end
  end
  return moved_total, false
end

--- Deliver items from storage to an output block.
-- @tparam {table...} inventories From logistics_sources.read_all.
-- @tparam string item Item id.
-- @tparam number count How many.
-- @tparam[opt] string output_handle Which output block; default the first one.
-- @tparam[opt] function on_move function(from, to, item, count), per move made
-- @treturn[1] table { moved, output } (moved may be less than count)
-- @treturn[2] nil
-- @treturn[2] string error message
function logistics_sorting.request(inventories, item, count, output_handle, on_move)
  local output = find_output(inventories, output_handle)
  if not output then
    return nil, "no output chest: give one the 'output' role in the Storage tab"
  end
  local moved = 0
  for _, storage in ipairs(storage_targets(inventories, output.source, item)) do
    if moved >= count then
      break
    end
    if storage.items and storage.items[item] then
      local taken, is_output_full = take_from(storage, output, item, count - moved, on_move)
      moved = moved + taken
      if is_output_full then
        break
      end
    end
  end
  return { moved = moved, output = output.handle }
end

return logistics_sorting
