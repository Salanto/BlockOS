--- The hub: one view over every logistics node, plus the levels (watched items, alarms).
--
-- The controller runs a hub over the nodes that report to it; a node without a
-- controller runs one over itself (lone mode), so a starter base works with a single
-- computer. Players' tools only ever talk to a hub (logistics_handlers).
--
-- Each node is an entry with its last report and a proxy that acts on it:
--   report  { totals = { [item] = { count, label } }, blocks = { { handle, label, role,
--             used?, size?, pos?, is_missing? } }, moves = { { from, to, item, count } },
--             sources, poll_seconds, pos? }
--   proxy   request(item, count, output_handle) -> { moved, output } | nil, err
--           set_storage({ storage, role?, label?, pos?, clear_pos?, forget? })
--             -> { storage } | nil, err
--           find_start() -> true | nil, err;  find_finish() -> { { handle, label } }
-- The local proxy calls the node directly; the controller's proxy uses rpc
-- (blockos.logistics.node).
-- @module logistics_hub

local logistics = import("logistics")
local logistics_alarms = import("logistics_alarms")

local logistics_hub = {}

logistics_hub.MAX_ALERTS = 20
logistics_hub.MAX_MOVES = 50
--- A node is shown as stale after this many rounds without a report.
logistics_hub.STALE_ROUNDS = 3
--- Seconds before a low item is asked to be crafted again (when no job shows up).
logistics_hub.CRAFT_RETRY_SECONDS = 60

-- How many of an item a node has: its last report, minus moves made since that the
-- report does not include yet (they wait in entry.pending until a report with their
-- seq arrives). A report never overwrites a fresher count this way, and a move is
-- never subtracted twice.
local function count_on(entry, item)
  local found = (entry.report.totals or {})[item]
  local count = found and found.count or 0
  for _, move in ipairs(entry.pending or {}) do
    if move.item == item then
      count = count - move.count
    end
  end
  return math.max(0, count)
end

--- Clock and time of day (tests replace these).
logistics_hub.env = {
  clock = function() return os.clock() end,
  time = function() return textutils.formatTime(os.time(), true) end,
  log = function() end,
}

local function everyone()
  return true
end

--- Create a hub.
-- @tparam table options
--   config    levels config (logistics.normalise), changed in place
--   save      function() -> true | nil, err
--   hostname  name used in alerts
--   title     optional, e.g. "Logistics kitchen"
--   transfer  optional function(from_entry, to_entry, item, count, output_handle)
--             -> { moved, output } | nil, err: carries items between nodes (the
--             controller's ports); without it items only move within one node
--   port_status  optional function(node, handle) -> "paired" | "pairing", for ports
--   defer     optional function(job): run slow work (asking a node to craft) later,
--             outside the caller (the controller's work loop); default: right away
-- @treturn table hub
function logistics_hub.new(options)
  local config = logistics.normalise(options.config)
  local hub = {
    config = config,
    nodes = {}, -- [name] = { name, report, proxy, seen }
    states = {},
    alerts = {},
    -- oldest first: { seq, node, from, to, item, label, count }, or for a crossing
    -- between nodes { seq, node (receiving), from_node, crossing = true, item, label, count }
    moves = {},
    move_seq = 0,
    -- Changes whenever the hub starts, so maps notice that seqs began again.
    move_log = os.epoch("utc"),
    applied_outputs = {},
    craft_asked = {}, -- [item] = clock of the last craft asked for a low item
  }

  function hub.save()
    return options.save()
  end

  ---------------------------------------------------------------------------
  -- Nodes
  ---------------------------------------------------------------------------

  local function is_stale(entry)
    local poll = entry.report.poll_seconds or logistics.DEFAULT_POLL_SECONDS
    return logistics_hub.env.clock() - entry.seen > poll * logistics_hub.STALE_ROUNDS
  end

  --- Node names in order, optionally only those `visible` allows.
  function hub.node_names(visible)
    visible = visible or everyone
    local names = {}
    for name in pairs(hub.nodes) do
      if visible(name) then
        names[#names + 1] = name
      end
    end
    table.sort(names)
    return names
  end

  --- Item totals over the nodes `visible` allows (default: all).
  -- @treturn table [item] = { count, label, nodes = { [node] = count } }
  function hub.totals(visible)
    local totals = {}
    for _, name in ipairs(hub.node_names(visible)) do
      local entry = hub.nodes[name]
      for item, found in pairs(entry.report.totals or {}) do
        local count = count_on(entry, item)
        local total = totals[item] or { count = 0, label = found.label, nodes = {} }
        total.count = total.count + count
        total.label = total.label or found.label
        total.nodes[name] = (total.nodes[name] or 0) + count
        totals[item] = total
      end
    end
    return totals
  end

  local function record_moves(name, moves)
    local totals = hub.nodes[name].report.totals or {}
    for _, move in ipairs(moves or {}) do
      hub.move_seq = hub.move_seq + 1
      local found = totals[move.item]
      hub.moves[#hub.moves + 1] = {
        seq = hub.move_seq,
        node = name,
        from = move.from,
        to = move.to,
        item = move.item,
        label = found and found.label or move.item,
        count = move.count,
      }
      if #hub.moves > logistics_hub.MAX_MOVES then
        table.remove(hub.moves, 1)
      end
    end
  end

  local function record_crossing(from_node, to_node, item, count)
    local found = (hub.nodes[from_node].report.totals or {})[item]
    hub.move_seq = hub.move_seq + 1
    hub.moves[#hub.moves + 1] = {
      seq = hub.move_seq,
      node = to_node,
      from_node = from_node,
      crossing = true,
      item = item,
      label = found and found.label or item,
      count = count,
    }
    if #hub.moves > logistics_hub.MAX_MOVES then
      table.remove(hub.moves, 1)
    end
  end

  --- A node reported (or, for a lone node, finished a round): store it, then check
  -- the levels against the new totals.
  -- @tparam string name Node hostname.
  -- @tparam table report See the module comment.
  -- @tparam table proxy How to act on the node.
  function hub.update(name, report, proxy)
    local entry = hub.nodes[name] or { name = name, pending = {} }
    local old = entry.report
    local is_same_run = old and report.boot ~= nil and report.boot == old.boot
    if is_same_run and (report.seq or 0) < (old.seq or 0) then
      return -- a late report: the newer one is already here
    end
    entry.report, entry.proxy, entry.seen = report, proxy, logistics_hub.env.clock()
    -- Moves this report includes no longer need subtracting (all of them when the
    -- node restarted: its counts are fresh).
    local kept = {}
    for _, move in ipairs(entry.pending or {}) do
      if is_same_run and move.seq and move.seq > (report.seq or 0) then
        kept[#kept + 1] = move
      end
    end
    entry.pending = kept
    hub.nodes[name] = entry
    record_moves(name, report.moves)
    hub.check_levels()
  end

  --- Forget a node (it was taken down for good).
  function hub.forget_node(name)
    if not hub.nodes[name] then
      return nil, "no node called " .. tostring(name)
    end
    hub.nodes[name] = nil
    return true
  end

  --- One row per node, for the Nodes tab.
  function hub.list_nodes(visible)
    local rows = {}
    local now = logistics_hub.env.clock()
    for _, name in ipairs(hub.node_names(visible)) do
      local entry = hub.nodes[name]
      local items, blocks = 0, 0
      for _ in pairs(entry.report.totals or {}) do
        items = items + 1
      end
      for _, block in ipairs(entry.report.blocks or {}) do
        if block.role ~= "ignore" and not block.is_missing then
          blocks = blocks + 1
        end
      end
      rows[#rows + 1] = {
        name = name,
        items = items,
        blocks = blocks,
        age = math.floor(now - entry.seen),
        is_stale = is_stale(entry),
        pos = entry.report.pos,
      }
    end
    return rows
  end

  ---------------------------------------------------------------------------
  -- Levels
  ---------------------------------------------------------------------------

  ---------------------------------------------------------------------------
  -- Crafting (nodes with logistics-crafting report their recipes and jobs)
  ---------------------------------------------------------------------------

  --- The node that can craft an item, if any.
  function hub.crafter_for(item, visible)
    for _, name in ipairs(hub.node_names(visible)) do
      local crafting = hub.nodes[name].report.crafting
      for _, craftable in ipairs(crafting and crafting.recipes or {}) do
        if craftable == item then
          return name
        end
      end
    end
    return nil
  end

  --- Every item some node can craft: [item] = node.
  function hub.craftable(visible)
    local items = {}
    for _, name in ipairs(hub.node_names(visible)) do
      local crafting = hub.nodes[name].report.crafting
      for _, item in ipairs(crafting and crafting.recipes or {}) do
        items[item] = items[item] or name
      end
    end
    return items
  end

  --- Crafting jobs of every node (running, waiting, and the last few finished).
  function hub.jobs(visible)
    local rows = {}
    for _, name in ipairs(hub.node_names(visible)) do
      local crafting = hub.nodes[name].report.crafting
      for _, job in ipairs(crafting and crafting.jobs or {}) do
        local row = { node = name }
        for key, value in pairs(job) do
          row[key] = value
        end
        rows[#rows + 1] = row
      end
    end
    return rows
  end

  local function has_open_job(name, item)
    local crafting = hub.nodes[name].report.crafting
    for _, job in ipairs(crafting and crafting.jobs or {}) do
      local is_open = job.state == "queued" or job.state == "running" or job.state == "waiting"
      if job.item == item and is_open then
        return true
      end
    end
    return false
  end

  --- Ask the node with the recipe to craft an item.
  function hub.craft(item, count, visible)
    local name = hub.crafter_for(item, visible)
    if not name then
      return nil, "no node has a recipe for " .. item
    end
    local proxy = hub.nodes[name].proxy
    if not proxy.craft then
      return nil, "node " .. name .. " cannot be asked to craft"
    end
    local result, err = proxy.craft(item, count)
    if not result then
      return nil, err
    end
    result.node = name
    return result
  end

  -- Keep stocked: a low watched item that a node can craft is crafted up to its refill
  -- target (or just above the limit), unless a job for it is already open.
  local function request_crafts(states)
    local now = logistics_hub.env.clock()
    for item, state in pairs(states) do
      local name = state.is_low and hub.crafter_for(item)
      local asked = hub.craft_asked[item]
      local is_due = not asked or now - asked >= logistics_hub.CRAFT_RETRY_SECONDS
      if name and is_due and not has_open_job(name, item) then
        local watch = config.watches[item]
        local wanted = logistics.recovery_level(watch) - state.count
        hub.craft_asked[item] = now
        local defer = options.defer or function(job) job() end
        defer(function()
          local result, err = hub.craft(item, math.max(1, wanted))
          if not result then
            logistics_hub.env.log("crafting %s on %s: %s", item, name, tostring(err))
          end
        end)
      end
    end
  end

  --- Compare the merged totals with the watched items and raise alarms.
  function hub.check_levels()
    local states, changes = logistics.evaluate(config, hub.totals(), hub.states)
    hub.states = states
    request_crafts(states)
    hub.updated = logistics_hub.env.time()

    local wanted = logistics.output_states(config, states)
    hub.applied_outputs = logistics_alarms.apply_redstone(wanted, hub.applied_outputs)
    for _, item in ipairs(changes.went_low) do
      logistics_hub.env.log("%s is low: %d of %d", states[item].label, states[item].count,
        states[item].limit)
    end
    if #changes.went_low > 0 and config.chime then
      logistics_alarms.chime(config.sound)
    end
    local sent = logistics_alarms.send_alerts(options.hostname, states, changes,
      logistics_alarms.EVERYONE)
    for _, alert in ipairs(sent) do
      -- The history shows when it happened (in-game time); not sent on the wire.
      local entry = { time = hub.updated }
      for key, value in pairs(alert) do
        entry[key] = value
      end
      hub.alerts[#hub.alerts + 1] = entry
      if #hub.alerts > logistics_hub.MAX_ALERTS then
        table.remove(hub.alerts, 1)
      end
    end
  end

  --- Nobody is counting any more: switch lamps and farms off rather than leave them.
  function hub.stop()
    logistics_alarms.apply_redstone({}, hub.applied_outputs)
    hub.applied_outputs = {}
  end

  function hub.snapshot()
    local sources = 0
    for _, entry in pairs(hub.nodes) do
      sources = sources + (entry.report.sources or 0)
    end
    return {
      title = options.title or "Logistics",
      updated = hub.updated,
      rows = logistics.sorted_rows(hub.states),
      sources = sources,
      nodes = #hub.node_names(),
    }
  end

  hub.list_outputs = logistics_alarms.list_outputs

  ---------------------------------------------------------------------------
  -- Storage and requests
  ---------------------------------------------------------------------------

  --- Every block of the visible nodes, with a node column, sorted by node and label.
  function hub.list_storages(visible)
    local rows = {}
    for _, name in ipairs(hub.node_names(visible)) do
      for _, block in ipairs(hub.nodes[name].report.blocks or {}) do
        local row = { node = name }
        for key, value in pairs(block) do
          row[key] = value
        end
        if row.role == "port" and options.port_status then
          row.port = options.port_status(name, row.handle)
        end
        rows[#rows + 1] = row
      end
    end
    table.sort(rows, function(a, b)
      if a.node ~= b.node then
        return a.node < b.node
      end
      return tostring(a.label) < tostring(b.label)
    end)
    return rows
  end

  local function has_output(name)
    for _, block in ipairs(hub.nodes[name].report.blocks or {}) do
      if block.role == "output" and not block.is_missing then
        return true
      end
    end
    return false
  end

  -- The node to take an item from when no output was named: the one with the most of
  -- it that has an output chest.
  local function pick_node(item, visible)
    local best, best_count = nil, 0
    local holding = nil
    for _, name in ipairs(hub.node_names(visible)) do
      local count = count_on(hub.nodes[name], item)
      if count > 0 then
        holding = holding or name
        if count > best_count and has_output(name) then
          best, best_count = name, count
        end
      end
    end
    if best then
      return best
    end
    if holding then
      return nil, "node " .. holding .. " has it but no output chest: give one the "
        .. "'output' role in the Storage tab"
    end
    return nil, "none in storage"
  end

  --- Output chests with a position (depots), nearest first when `near` is given.
  -- @tparam[opt] table near { x, y, z }
  -- @tparam[opt] function visible
  -- @treturn {table...} { node, handle, label, pos, distance? }
  function hub.depots(near, visible)
    local depots = {}
    for _, name in ipairs(hub.node_names(visible)) do
      for _, block in ipairs(hub.nodes[name].report.blocks or {}) do
        if block.role == "output" and block.pos and not block.is_missing then
          depots[#depots + 1] = {
            node = name,
            handle = block.handle,
            label = block.label or block.handle,
            pos = block.pos,
            distance = near and logistics.distance(near, block.pos) or nil,
          }
        end
      end
    end
    if near then
      table.sort(depots, function(a, b) return a.distance < b.distance end)
    end
    return depots
  end

  -- The depot for a request near a place: the nearest whose node has enough of the
  -- item, else the nearest whose node has some.
  local function pick_depot(item, count, near, visible)
    local fallback = nil
    for _, depot in ipairs(hub.depots(near, visible)) do
      local stored = count_on(hub.nodes[depot.node], item)
      if stored >= count then
        return depot
      end
      if stored > 0 and not fallback then
        fallback = depot
      end
    end
    if fallback then
      return fallback
    end
    return nil, "no depot has any: give an output chest next to the items a position "
      .. "(logistics storage pos)"
  end

  -- The counts drop at once, so the Catalog and a second request do not see items that
  -- already left (the next report corrects any difference).
  -- The counts drop at once until the node's report includes the move (`seq`: the
  -- first report that does; without one, the next report).
  local function took(name, item, moved, seq)
    local entry = hub.nodes[name]
    if entry and moved > 0 then
      entry.pending = entry.pending or {}
      entry.pending[#entry.pending + 1] = { item = item, count = moved,
        seq = seq or ((entry.report.seq or 0) + 1) }
    end
  end

  local function stored_on(name, item)
    return count_on(hub.nodes[name], item)
  end

  -- The node with the most of an item, other than `except`.
  local function richest(item, visible, except)
    local best, best_count = nil, 0
    for _, name in ipairs(hub.node_names(visible)) do
      local count = stored_on(name, item)
      if name ~= except and count > best_count then
        best, best_count = name, count
      end
    end
    return best
  end

  -- Where to deliver when nothing was named. With ports, any node with an output will
  -- do when the nodes holding the item have none.
  local function pick_target(item, count, near, visible)
    if near then
      local depot, err = pick_depot(item, count, near, visible)
      if not depot and options.transfer then
        depot = hub.depots(near, visible)[1]
      end
      if not depot then
        return nil, nil, err
      end
      return depot.node, depot
    end
    local name, err = pick_node(item, visible)
    if not name and options.transfer and richest(item, visible) then
      for _, candidate in ipairs(hub.node_names(visible)) do
        if has_output(candidate) then
          return candidate
        end
      end
    end
    return name, nil, err
  end

  --- Deliver items to an output chest. With ports (the controller's `transfer`),
  -- what the output's node lacks comes from the node with the most of it.
  -- @tparam string item Item id.
  -- @tparam number count
  -- @tparam[opt] table output A row from list_storages (its node delivers); default: the
  --   node with the most of the item that has an output.
  -- @tparam[opt] function visible Which nodes the caller may use.
  -- @tparam[opt] table near { x, y, z }: deliver to the nearest depot (output chest
  --   with a position) instead
  -- @treturn[1] table { moved, output, output_label?, pos?, node, from? }
  -- @treturn[2] nil
  -- @treturn[2] string error message
  function hub.request(item, count, output, visible, near)
    local name, err
    if output then
      name = output.node
    else
      name, output, err = pick_target(item, count, near, visible)
    end
    if not name then
      return nil, err
    end
    local entry = hub.nodes[name]
    if not entry then
      return nil, "no node called " .. tostring(name)
    end
    local transfer = options.transfer
    local handle = output and output.handle
    local have = stored_on(name, item)
    local moved, source = 0, nil

    if have > 0 or not transfer then
      local wanted = transfer and math.min(count, have) or count
      local result, request_error = entry.proxy.request(item, wanted, handle)
      if not result then
        return nil, request_error
      end
      moved = result.moved or 0
      handle = handle or result.output
      took(name, item, moved, result.seq)
    end

    if transfer and moved < count then
      source = richest(item, visible, name)
      if source then
        local crossed, cross_error = transfer(hub.nodes[source], entry, item, count - moved, handle)
        if crossed then
          record_crossing(source, name, item, crossed.moved or 0)
          took(source, item, crossed.moved or 0, crossed.seq)
          moved = moved + (crossed.moved or 0)
          handle = handle or crossed.output
        elseif moved == 0 then
          return nil, cross_error
        end
      elseif moved == 0 then
        return nil, "none in storage"
      end
    end

    return {
      moved = moved,
      output = handle,
      node = name,
      from = source,
      output_label = output and output.label,
      pos = output and output.pos,
    }
  end

  --- Change a block's role, label or position (or forget a missing one) on its node.
  -- @tparam table row From list_storages.
  -- @tparam table change { role?, label?, pos?, clear_pos?, forget? }
  function hub.set_storage(row, change)
    local entry = hub.nodes[row.node]
    if not entry then
      return nil, "no node called " .. tostring(row.node)
    end
    local result, err = entry.proxy.set_storage({
      storage = row.handle,
      role = change.role,
      label = change.label,
      pos = change.pos,
      clear_pos = change.clear_pos,
      forget = change.forget,
    })
    if not result then
      return nil, err
    end
    -- Show the change at once; the next report confirms it.
    for index, block in ipairs(entry.report.blocks or {}) do
      if block.handle == row.handle then
        if change.forget then
          table.remove(entry.report.blocks, index)
        else
          block.role = change.role or block.role
          if change.clear_pos then
            block.pos = nil
          elseif change.pos then
            block.pos = logistics.clean_pos(change.pos)
          end
          if change.label then
            block.label = change.label ~= "" and change.label or block.handle
          end
        end
        break
      end
    end
    result.node = row.node
    return result
  end

  --- Find a chest, step 1: every visible node pauses sorting and remembers its blocks.
  function hub.find_start(visible)
    for _, name in ipairs(hub.node_names(visible)) do
      local ok, err = hub.nodes[name].proxy.find_start()
      if not ok then
        logistics_hub.env.log("find on %s: %s", name, tostring(err))
      end
    end
    return true
  end

  --- Find a chest, step 2: the blocks whose contents changed, on any visible node.
  function hub.find_finish(visible)
    local changed = {}
    for _, name in ipairs(hub.node_names(visible)) do
      for _, block in ipairs(hub.nodes[name].proxy.find_finish() or {}) do
        changed[#changed + 1] = { node = name, handle = block.handle, label = block.label }
      end
    end
    return changed
  end

  --- Bring an ingredient from other nodes into a machine of `node` (asked by its
  -- crafter when its own storage lacks it). Needs ports.
  function hub.supply(node, item, count, target)
    local entry = hub.nodes[node]
    if not entry then
      return nil, "no node called " .. tostring(node)
    end
    if not options.transfer then
      return nil, "items cannot cross between nodes here"
    end
    local source = richest(item, nil, node)
    if not source then
      return nil, "no other node has " .. item
    end
    local result, err = options.transfer(hub.nodes[source], entry, item, count, target)
    if result then
      record_crossing(source, node, item, result.moved or 0)
      took(source, item, result.moved or 0, result.seq)
    end
    return result, err
  end

  return hub
end

return logistics_hub
