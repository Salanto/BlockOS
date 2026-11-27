--- The hub: one view over every logistics node, plus the levels (watched items, alarms).
--
-- The controller runs a hub over the nodes that report to it; a node without a
-- controller runs one over itself (lone mode), so a starter base works with a single
-- computer. Players' tools only ever talk to a hub (logistics_handlers).
--
-- Each node is an entry with its last report and a proxy that acts on it:
--   report  { totals = { [item] = { count, label } }, blocks = { { handle, label, role,
--             used?, size?, is_missing? } }, moves = { { from, to, item, count } },
--             sources, poll_seconds }
--   proxy   request(item, count, output_handle) -> { moved, output } | nil, err
--           set_storage({ storage, role?, label?, forget? }) -> { storage } | nil, err
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
-- @treturn table hub
function logistics_hub.new(options)
  local config = logistics.normalise(options.config)
  local hub = {
    config = config,
    nodes = {}, -- [name] = { name, report, proxy, seen }
    states = {},
    alerts = {},
    moves = {}, -- oldest first: { seq, node, from, to, item, label, count }
    move_seq = 0,
    -- Changes whenever the hub starts, so maps notice that seqs began again.
    move_log = os.epoch("utc"),
    applied_outputs = {},
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
      for item, found in pairs(hub.nodes[name].report.totals or {}) do
        local total = totals[item] or { count = 0, label = found.label, nodes = {} }
        total.count = total.count + found.count
        total.label = total.label or found.label
        total.nodes[name] = (total.nodes[name] or 0) + found.count
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

  --- A node reported (or, for a lone node, finished a round): store it, then check
  -- the levels against the new totals.
  -- @tparam string name Node hostname.
  -- @tparam table report See the module comment.
  -- @tparam table proxy How to act on the node.
  function hub.update(name, report, proxy)
    local entry = hub.nodes[name] or { name = name }
    entry.report, entry.proxy, entry.seen = report, proxy, logistics_hub.env.clock()
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

  --- Compare the merged totals with the watched items and raise alarms.
  function hub.check_levels()
    local states, changes = logistics.evaluate(config, hub.totals(), hub.states)
    hub.states = states
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
      local found = (hub.nodes[name].report.totals or {})[item]
      local count = found and found.count or 0
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

  -- The counts drop at once, so the Catalog and a second request do not see items that
  -- already left (the next report corrects any difference).
  local function took(name, item, moved)
    local found = (hub.nodes[name].report.totals or {})[item]
    if found then
      found.count = math.max(0, found.count - moved)
    end
  end

  --- Deliver items to an output chest.
  -- @tparam string item Item id.
  -- @tparam number count
  -- @tparam[opt] table output A row from list_storages (its node delivers); default: the
  --   node with the most of the item that has an output.
  -- @tparam[opt] function visible Which nodes the caller may use.
  -- @treturn[1] table { moved, output, node }
  -- @treturn[2] nil
  -- @treturn[2] string error message
  function hub.request(item, count, output, visible)
    local name, err
    if output then
      name = output.node
    else
      name, err = pick_node(item, visible)
    end
    if not name then
      return nil, err
    end
    local entry = hub.nodes[name]
    if not entry then
      return nil, "no node called " .. tostring(name)
    end
    local result, request_error = entry.proxy.request(item, count, output and output.handle)
    if not result then
      return nil, request_error
    end
    took(name, item, result.moved or 0)
    result.node = name
    return result
  end

  --- Change a block's role or label (or forget a missing one) on its node.
  -- @tparam table row From list_storages.
  -- @tparam table change { role?, label?, forget? }
  function hub.set_storage(row, change)
    local entry = hub.nodes[row.node]
    if not entry then
      return nil, "no node called " .. tostring(row.node)
    end
    local result, err = entry.proxy.set_storage({
      storage = row.handle,
      role = change.role,
      label = change.label,
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

  return hub
end

return logistics_hub
