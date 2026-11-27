--- The hub: one view over every logistics node, plus the levels (watched items, alarms).
-- This module has the nodes, their totals and the move log; logistics_hub_levels adds
-- levels and keep-stocked crafting, logistics_hub_routing adds requests, depots and
-- crossings.
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

local logistics_hub = {}

logistics_hub.MAX_ALERTS = 20
logistics_hub.MAX_MOVES = 50
--- A node is shown as stale after this many rounds without a report.
logistics_hub.STALE_ROUNDS = 3
--- Seconds before a low item is asked to be crafted again (when no job shows up).
logistics_hub.CRAFT_RETRY_SECONDS = 60
--- Seconds before an item whose last job failed is asked again.
logistics_hub.CRAFT_BACKOFF_SECONDS = 300
--- Levels (alarms, keep-stocked) are checked at most this often: with many nodes a
-- report arrives every second or so, and one check covers them all.
logistics_hub.LEVELS_SECONDS = 2

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
--   log       optional function(format, ...) for warnings (default: env.log)
--   send      optional function(id, message, protocol): pushes new moves to subscribers
--             (default: rednet, or a local event for this computer)
--   transfer  optional function(from_entry, to_entry, item, count, output_handle)
--             -> { moved, output } | nil, err: carries items between nodes (the
--             controller's ports); without it items only move within one node
--   port_status  optional function(node, handle) -> "paired" | "pairing", for ports
--   defer     optional function(job): run slow work (asking a node to craft) later,
--             outside the caller (the controller's work loop); default: right away
-- @treturn table hub
function logistics_hub.new(options)
  local config = logistics.normalise(options.config)
  local log = options.log or logistics_hub.env.log
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
    subscribers = {}, -- [computer id] = { until_clock, visible? }: pushed new moves
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

  -- Nodes that answer: routing (requests, crossings, crafting, finding a chest) skips
  -- stale ones, whose last counts still go into the levels (the items exist, just out
  -- of reach while the node's chunk is unloaded).
  local function live_names(visible)
    local names = {}
    for _, name in ipairs(hub.node_names(visible)) do
      if not is_stale(hub.nodes[name]) then
        names[#names + 1] = name
      end
    end
    return names
  end

  --- A node that reports under a new name from the same computer was renamed: move
  -- its entry instead of counting its items twice.
  function hub.rename_node(old, new)
    if hub.nodes[old] and not hub.nodes[new] then
      hub.nodes[new] = hub.nodes[old]
      hub.nodes[new].name = new
      hub.nodes[old] = nil
      return true
    end
    return false
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

  -- Push new moves to the computers that subscribed (each sees only nodes it may).
  local function push_moves(moves)
    local now = logistics_hub.env.clock()
    local client = import("logistics_client")
    local send = options.send or function(id, message, protocol)
      if id == os.getComputerID() then
        os.queueEvent("rednet_message", id, message, protocol)
      else
        rednet.send(id, message, protocol)
      end
    end
    for id, subscriber in pairs(hub.subscribers) do
      if subscriber.until_clock < now then
        hub.subscribers[id] = nil
      else
        local visible = {}
        for _, move in ipairs(moves) do
          if not subscriber.visible or subscriber.visible(move.node) then
            visible[#visible + 1] = move
          end
        end
        if #visible > 0 then
          send(id, import("wire").event(client.MOVES_TOPIC, { moves = visible }),
            client.MOVES_PROTOCOL)
        end
      end
    end
  end

  --- Push new moves to a computer for the next lease (wall boards).
  -- @tparam number id
  -- @tparam[opt] function visible Which nodes it may see.
  function hub.subscribe_moves(id, visible)
    local lease = import("logistics_client").MOVES_LEASE
    hub.subscribers[id] = { until_clock = logistics_hub.env.clock() + lease, visible = visible }
    return { lease = lease }
  end

  local function record_moves(name, moves)
    local new = {}
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
      new[#new + 1] = hub.moves[#hub.moves]
      if #hub.moves > logistics_hub.MAX_MOVES then
        table.remove(hub.moves, 1)
      end
    end
    if #new > 0 then
      push_moves(new)
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
    push_moves({ hub.moves[#hub.moves] })
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
    if report.blocks == nil and old then
      report.blocks = old.blocks -- unchanged since the last list (see logistics_node)
    end
    -- Labels come only when new (see logistics_node): keep the ones already known.
    local old_totals = old and old.totals or {}
    for item, found in pairs(report.totals or {}) do
      found.label = found.label or (old_totals[item] and old_totals[item].label) or item
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
    hub.note_crafting(entry)
    hub.check_nodes() -- a node that was stale is back
    record_moves(name, report.moves)
    hub.levels_due = true
    hub.check_levels_if_due()
  end

  --- Check the levels if a report came in and the last check is old enough (the
  -- controller also calls this every couple of seconds, for reports held back).
  function hub.check_levels_if_due()
    local now = logistics_hub.env.clock()
    local is_old = not hub.levels_at or now - hub.levels_at >= logistics_hub.LEVELS_SECONDS
    if hub.levels_due and is_old then
      hub.check_levels()
    end
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

  -- The levels (alarms, keep-stocked crafting) and the routing (requests, depots,
  -- crossings) are in their own modules; they share these internals.
  local internal = {
    options = options,
    config = config,
    log = log,
    count_on = count_on,
    is_stale = is_stale,
    live_names = live_names,
    record_crossing = record_crossing,
  }
  import("logistics_hub_levels").attach(hub, internal)
  import("logistics_hub_routing").attach(hub, internal)

  return hub
end

return logistics_hub
