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

--- Empty every input block (and port) into storage (one capped round).
-- @tparam {table...} inventories From logistics_sources.read_all.
-- @tparam[opt] function on_move function(from, to, item, count), per move made
-- @tparam[opt] boolean skip_ports Leave ports alone (an item is crossing right now).
-- @treturn number Moves made.
-- @treturn {table...} failures: { handle, error }, for the log
function logistics_sorting.sort_inputs(inventories, on_move, skip_ports)
  local moves = 0
  local failures = {}
  for _, input in ipairs(inventories) do
    local is_input = input.role == "input" or (input.role == "port" and not skip_ports)
    if is_input and can_move(input.source) then
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

local function find_block(inventories, role, handle)
  for _, inventory in ipairs(inventories) do
    local is_wanted = handle == nil or inventory.handle == handle
    if inventory.role == role and is_wanted and can_move(inventory.source) then
      return inventory
    end
  end
  return nil
end

local function find_output(inventories, handle)
  return find_block(inventories, "output", handle)
end

-- Take up to `wanted` of an item out of one storage block into the output.
local function take_from(storage, output, item, wanted, on_move, to_slot)
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
        wanted - moved_total, to_slot)
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
  return logistics_sorting.deliver(inventories, item, count, output, on_move)
end

--- Move items from storage into one block (an output, or a port for another node).
-- @tparam {table...} inventories
-- @tparam string item
-- @tparam number count
-- @tparam table target An entry of `inventories`.
-- @tparam[opt] function on_move
-- @treturn table { moved, output }
-- @tparam[opt] number to_slot A slot of the target (a furnace's input or fuel slot).
function logistics_sorting.deliver(inventories, item, count, target, on_move, to_slot)
  local output = target
  local moved = 0
  for _, storage in ipairs(storage_targets(inventories, output.source, item)) do
    if moved >= count then
      break
    end
    if storage.items and storage.items[item] then
      local taken, is_output_full = take_from(storage, output, item, count - moved, on_move,
        to_slot)
      moved = moved + taken
      if is_output_full then
        break
      end
    end
  end
  return { moved = moved, output = output.handle }
end

--- Move items into a port, for the controller to carry to another node.
-- @treturn[1] table { moved, output }
-- @treturn[2] nil
-- @treturn[2] string error message
function logistics_sorting.to_port(inventories, item, count, port_handle, on_move)
  local port = find_block(inventories, "port", port_handle)
  if not port then
    return nil, "no port called " .. tostring(port_handle)
  end
  return logistics_sorting.deliver(inventories, item, count, port, on_move)
end

--- Move items from storage into a machine block (a crafting supply step).
-- @treturn[1] table { moved, output }
-- @treturn[2] nil
-- @treturn[2] string error message
function logistics_sorting.supply(inventories, item, count, machine_handle, on_move, to_slot)
  local machine = find_block(inventories, "machine", machine_handle)
  if not machine then
    return nil, "no machine called " .. tostring(machine_handle)
  end
  return logistics_sorting.deliver(inventories, item, count, machine, on_move, to_slot)
end

--- Move everything out of one block into storage (crafting results, or what is left
-- after a failed attempt).
-- @treturn[1] number Items moved.
-- @treturn[2] nil
-- @treturn[2] string error message
function logistics_sorting.empty_block(inventories, handle, on_move)
  local block = nil
  for _, inventory in ipairs(inventories) do
    if inventory.handle == handle and can_move(inventory.source) then
      block = inventory
    end
  end
  if not block then
    return nil, "no block called " .. tostring(handle)
  end
  local ok, slots = pcall(block.source.list, block.handle)
  if not ok then
    return nil, tostring(slots)
  end
  local moved = 0
  for slot, stack in pairs(slots) do
    local _, err = sort_slot(inventories, block, slot, stack, logistics_sorting.MAX_MOVES,
      function(from, to, item, count)
        moved = moved + count
        if on_move then
          on_move(from, to, item, count)
        end
      end)
    if err then
      return moved > 0 and moved or nil, err
    end
  end
  return moved
end

--- Move items that arrived in a port on to an output.
-- @treturn[1] table { moved, output }
-- @treturn[2] nil
-- @treturn[2] string error message
function logistics_sorting.from_port(inventories, port_handle, item, count, output_handle,
    on_move)
  local port = find_block(inventories, "port", port_handle)
  -- Usually an output; a crafting node also has ingredients brought to a machine.
  local output = find_output(inventories, output_handle)
    or (output_handle and find_block(inventories, "machine", output_handle))
  if not port then
    return nil, "no port called " .. tostring(port_handle)
  end
  if not output then
    return nil, "no output chest: give one the 'output' role in the Storage tab"
  end
  local moved = take_from(port, output, item, count, on_move)
  -- What is still in the port (an output that was full): tells a full output from a
  -- port the items never reached.
  local left = 0
  local ok, slots = pcall(port.source.list, port.handle)
  for _, stack in pairs(ok and slots or {}) do
    if stack.name == item then
      left = left + stack.count
    end
  end
  return { moved = moved, output = output.handle, left = left }
end

--- Put one item from storage into a port, so the controller can tell which block on
-- the main cable it is (the one that changed). It is sorted back later.
-- @treturn[1] table { item }
-- @treturn[2] nil
-- @treturn[2] string error message
function logistics_sorting.push_marker(inventories, port_handle, on_move)
  local port = find_block(inventories, "port", port_handle)
  if not port then
    return nil, "no port called " .. tostring(port_handle)
  end
  for _, storage in ipairs(inventories) do
    if storage.role == "storage" and storage.source == port.source and storage.items then
      for item in pairs(storage.items) do
        local moved = take_from(storage, port, item, 1, on_move)
        if moved > 0 then
          return { item = item }
        end
      end
    end
  end
  return nil, "nothing in storage to mark the port with"
end

return logistics_sorting
