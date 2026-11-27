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
-- controller asks the node to drop one item into it and looks which inventory on the
-- main cable changed. Pairings are kept in the controller's config (`ports`,
-- "node/handle" -> name on the main cable).
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

-- Items per inventory on the main cable.
local function main_totals()
  local api = logistics_ports.env.peripheral
  local totals = {}
  for _, name in ipairs(api.getNames()) do
    if api.hasType(name, "inventory") then
      local ok, slots = pcall(function() return api.wrap(name).list() end)
      if ok and slots then
        local total = 0
        for _, stack in pairs(slots) do
          total = total + stack.count
        end
        totals[name] = total
      end
    end
  end
  return totals
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
  local ports = { attempts = {} }

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
    local before = main_totals()
    local marked, err = proxy.push_marker(handle)
    if not marked then
      return nil, err
    end
    local changed = {}
    for name, total in pairs(main_totals()) do
      if total > (before[name] or 0) then
        changed[#changed + 1] = name
      end
    end
    if #changed ~= 1 then
      return nil, "could not tell which block on the main cable is the port ("
        .. #changed .. " changed); is its second modem on the controller's cable and red?"
    end
    config.ports[key(node, handle)] = changed[1]
    save()
    return changed[1]
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
    return { moved = delivered.moved, output = delivered.output, seq = sent.seq }
  end

  return ports
end

return logistics_ports
