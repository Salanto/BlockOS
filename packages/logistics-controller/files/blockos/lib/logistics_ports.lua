--- Ports: how items cross between logistics nodes.
--
-- A port is an inventory with two wired modems: one on its node's storage network and
-- one on the main cable, which the controller is on too. Items move only within one
-- wired network (pushItems), so a crossing is a chain of three moves:
--   node A: storage -> port A   (rpc to_port)
--   controller: port A -> port B over the main cable (pushItems)
--   node B: port B -> output    (rpc from_port; node B held its ports meanwhile)
-- Whatever is left in a port (a full output, a lost answer) is sorted back into storage
-- by that node's next round, so nothing gets stranded.
--
-- Pairing is automatic: when a node reports a block with the role "port", the
-- controller asks the node to drop one item into it and looks for the inventory on the
-- main cable where exactly that item went up by one. No crossing runs meanwhile, and a
-- chest that is already another port is never chosen. Pairings are kept in the
-- controller's config (`ports`, "node/handle" -> name on the main cable). A crossing
-- whose items arrive in a port but never reach the node's side means the pairing is
-- wrong: it is dropped and done again.
-- @module logistics_ports

local logistics_ports = {}

--- Seconds before a failed pairing is tried again.
logistics_ports.RETRY_SECONDS = 60

--- The main cable and the clock (tests replace these).
logistics_ports.env = {
  peripheral = peripheral,
  clock = function() return os.clock() end,
}

local function key(node, handle)
  return node .. "/" .. handle
end

--- Most seconds a crossing waits for a pairing to finish.
logistics_ports.PAIRING_WAIT = 10

-- How many of one item each inventory on the main cable holds.
local function main_counts(item, skip)
  local api = logistics_ports.env.peripheral
  local counts = {}
  for _, name in ipairs(api.getNames()) do
    if not skip[name] and api.hasType(name, "inventory") then
      local ok, slots = pcall(function() return api.wrap(name).list() end)
      if ok and slots then
        local count = 0
        for _, stack in pairs(slots) do
          if stack.name == item then
            count = count + stack.count
          end
        end
        counts[name] = count
      end
    end
  end
  return counts
end

-- Push up to `count` of an item from one main-cable inventory to another.
local function carry(from, to, item, count)
  local api = logistics_ports.env.peripheral
  local source = api.wrap(from)
  if not source then
    return 0
  end
  local moved = 0
  for slot, stack in pairs(source.list()) do
    if moved >= count then
      break
    end
    if stack.name == item then
      local ok, pushed = pcall(source.pushItems, to, slot, count - moved)
      if not ok or (pushed or 0) == 0 then
        break
      end
      moved = moved + pushed
    end
  end
  return moved
end

--- Create the port registry.
-- @tparam table config The controller config (`ports` is added).
-- @tparam function save function() -> true | nil, err
-- @treturn table ports
function logistics_ports.new(config, save)
  config.ports = config.ports or {}
  local ports = { attempts = {}, is_pairing = false, crossings = 0 }

  -- Chests already paired to a port (never chosen for another).
  local function paired_chests(except)
    local taken = {}
    for paired, main in pairs(config.ports) do
      if paired ~= except then
        taken[main] = true
      end
    end
    return taken
  end

  --- After a report: drop pairings of blocks that are no longer ports, and list the
  -- ports that still need pairing (not tried in the last RETRY_SECONDS).
  -- @tparam string node
  -- @tparam {table...} blocks The report's blocks.
  -- @treturn {string...} handles to pair
  function ports.check(node, blocks)
    local is_port, wanted = {}, {}
    for _, block in ipairs(blocks or {}) do
      if block.role == "port" and not block.is_missing then
        is_port[block.handle] = true
        local tried = ports.attempts[key(node, block.handle)]
        local is_due = not tried
          or logistics_ports.env.clock() - tried >= logistics_ports.RETRY_SECONDS
        if not config.ports[key(node, block.handle)] and is_due then
          wanted[#wanted + 1] = block.handle
        end
      end
    end
    local changed = false
    for paired in pairs(config.ports) do
      local paired_node, handle = paired:match("^(.-)/(.*)$")
      if paired_node == node and not is_port[handle] then
        config.ports[paired] = nil
        changed = true
      end
    end
    if changed then
      save()
    end
    return wanted
  end

  --- Pair one port: the node drops a marker item into it, and the inventory on the main
  -- cable that changed is the same block.
  -- @tparam string node
  -- @tparam string handle The port's name on the node's storage network.
  -- @tparam table proxy The node's proxy (push_marker).
  -- @treturn[1] string The port's name on the main cable.
  -- @treturn[2] nil
  -- @treturn[2] string error message
  function ports.pair(node, handle, proxy)
    ports.attempts[key(node, handle)] = logistics_ports.env.clock()
    if ports.crossings > 0 then
      return nil, "items are crossing right now; trying again later"
    end
    ports.is_pairing = true
    local ok, result, err = pcall(function()
      -- The marker's item is known only afterwards: count everything before.
      local skip = paired_chests(key(node, handle))
      local api = logistics_ports.env.peripheral
      local before = {}
      for _, name in ipairs(api.getNames()) do
        if not skip[name] and api.hasType(name, "inventory") then
          local listed, slots = pcall(function() return api.wrap(name).list() end)
          before[name] = listed and slots or {}
        end
      end
      local marked, mark_error = proxy.push_marker(handle)
      if not marked then
        return nil, mark_error
      end
      local changed = {}
      for name, count in pairs(main_counts(marked.item, skip)) do
        local had = 0
        for _, stack in pairs(before[name] or {}) do
          if stack.name == marked.item then
            had = had + stack.count
          end
        end
        if count == had + 1 then
          changed[#changed + 1] = name
        end
      end
      if #changed ~= 1 then
        return nil, "could not tell which block on the main cable is the port ("
          .. #changed .. " candidates); is its second modem on the controller's cable and red?"
      end
      config.ports[key(node, handle)] = changed[1]
      save()
      return changed[1]
    end)
    ports.is_pairing = false
    if not ok then
      return nil, tostring(result)
    end
    return result, err
  end

  --- Forget a pairing that turned out wrong; it is paired again on the next report.
  function ports.unpair(node, handle)
    config.ports[key(node, handle)] = nil
    ports.attempts[key(node, handle)] = nil
    save()
  end

  --- A node's first paired port.
  -- @treturn[1] string handle on the node
  -- @treturn[1] string name on the main cable
  function ports.port_of(node)
    local found_handle, found_main = nil, nil
    for paired, main in pairs(config.ports) do
      local paired_node, handle = paired:match("^(.-)/(.*)$")
      if paired_node == node and (not found_handle or handle < found_handle) then
        found_handle, found_main = handle, main
      end
    end
    return found_handle, found_main
  end

  --- "paired" or "pairing" for a port block (shown in the Storage tab).
  function ports.status(node, handle)
    return config.ports[key(node, handle)] and "paired" or "pairing"
  end

  --- Carry items from one node to an output on another (the hub's transfer).
  -- @tparam table from_entry Hub node entry { name, proxy }.
  -- @tparam table to_entry
  -- @tparam string item
  -- @tparam number count
  -- @tparam[opt] string output Output handle on the receiving node.
  -- @treturn[1] table { moved, output }
  -- @treturn[2] nil
  -- @treturn[2] string error message
  function ports.transfer(from_entry, to_entry, item, count, output)
    local waited = 0
    while ports.is_pairing and waited < logistics_ports.PAIRING_WAIT do
      sleep(0.5)
      waited = waited + 0.5
    end
    if ports.is_pairing then
      return nil, "a port is being paired; try again in a moment"
    end
    ports.crossings = ports.crossings + 1
    local ok, result, err = pcall(ports.cross, from_entry, to_entry, item, count, output)
    ports.crossings = ports.crossings - 1
    if not ok then
      return nil, tostring(result)
    end
    return result, err
  end

  -- The crossing itself (see the module comment).
  function ports.cross(from_entry, to_entry, item, count, output)
    local from_handle, from_main = ports.port_of(from_entry.name)
    local to_handle, to_main = ports.port_of(to_entry.name)
    for name, handle in pairs({ [from_entry.name] = from_handle, [to_entry.name] = to_handle }) do
      if not handle then
        return nil, "node " .. name .. " has no port yet: give a chest that is on both its "
          .. "storage network and the main cable the 'port' role"
      end
    end
    -- Each crossing holds the ports under its own name until its last step.
    local hold = string.format("x%d-%d", math.random(0, 0x7fffffff), os.epoch("utc"))
    to_entry.proxy.port_hold(nil, hold)
    local sent, send_error = from_entry.proxy.to_port(item, count, from_handle, hold)
    if not sent then
      return nil, send_error
    end
    if (sent.moved or 0) == 0 then
      return nil, "node " .. from_entry.name .. " could not fill its port"
    end
    local carried = carry(from_main, to_main, item, sent.moved)
    if carried == 0 then
      return nil, "the port of " .. to_entry.name .. " is full"
    end
    local delivered, deliver_error = to_entry.proxy.from_port(to_handle, item, carried, output,
      hold)
    if not delivered then
      return nil, deliver_error
    end
    if (delivered.moved or 0) == 0 and (delivered.left or 0) == 0 then
      -- The items went into the chest we think is the port, but the node does not see
      -- them: that chest is not its port. Pair it again; whatever landed in the wrong
      -- chest has to be picked up by hand (the log says where).
      ports.unpair(to_entry.name, to_handle)
      return nil, "the port of " .. to_entry.name .. " seems paired to the wrong chest ("
        .. to_main .. "); pairing it again"
    end
    return { moved = delivered.moved, output = delivered.output, seq = sent.seq }
  end

  return ports
end

return logistics_ports
