--- A logistics node: one computer per storage network. Every round it reads its
-- blocks, sorts its input chests into storage and reports to the controller; on the
-- controller's request it delivers items, changes block roles and helps find a chest.
--
-- Nodes exist so that many computers each count a small network in parallel: every
-- inventory read costs a game tick, so one computer reading a whole base is slow.
--
-- Protocol "blockos.logistics.node" (wire):
--   node -> controller  event "report" { node, seq, boot, totals, blocks, moves,
--                       sources, poll_seconds } (full state each round, so it corrects
--                       itself; seq counts reports since `boot`, so a late report is
--                       recognised, and moves answer with the seq that first includes
--                       them)
--   controller -> node  rpc request { item, count, output? }, set_storage { storage,
--                       role?, label?, pos?, clear_pos?, forget? }, find_start, find_finish,
--                       export_levels; ports (M3): port_hold { seconds }, to_port { item,
--                       count, port }, from_port { port, item, count, output? },
--                       push_marker { port }; crafting: craft { item, count } (when the
--                       logistics-crafting package runs on this node)
-- In a domain only joined computers may call a node (computer token); without one it
-- is open, like everything standalone.
-- @module logistics_node

local rpc = import("rpc")
local logistics = import("logistics")
local logistics_sorting = import("logistics_sorting")
local logistics_sources = import("logistics_sources")

local logistics_node = {}

--- Moves kept for the next report (the rest are dropped; they are only animations).
logistics_node.MAX_MOVES = 50
--- The block list goes out only when it changed, or at least every this many reports
-- (a lost report is corrected by then). Item counts go out every round.
logistics_node.BLOCKS_EVERY = 6
--- Sorting pauses while someone finds a chest, at most this long.
logistics_node.FIND_PAUSE_SECONDS = 60
--- Ports are left alone this long while items cross (or a marker is read).
logistics_node.PORT_HOLD_SECONDS = 15



--- Clock (tests replace it).
logistics_node.env = {
  clock = function() return os.clock() end,
}

------------------------------------------------------------------------------
-- Choosing the storage modem (setup without questions)
------------------------------------------------------------------------------

--- Work out which modem is the storage network: the wired modem that sees
-- inventories. The other modem (wired or wireless) is the main network.
-- @tparam[opt] table api The peripheral API.
-- @treturn table { storage_side?, is_shared?, is_ambiguous? }: no storage_side when no
--   modem sees inventories (blocks placed against the computer still count);
--   is_shared when that modem is the only one (it then carries rednet too and is
--   not closed); is_ambiguous when several modems see inventories (the one seeing
--   the most is picked; `logistics node side` changes it). A modem with other
--   computers behind it is the main network: it is picked only when nothing else sees
--   chests, and then counts as shared (never closed: the node would drop off rednet).
function logistics_node.detect_sides(api)
  api = api or peripheral
  local modems, candidates = 0, {}
  for _, side in ipairs(logistics.SIDES) do
    if api.isPresent(side) and api.hasType(side, "modem") then
      modems = modems + 1
      local modem = api.wrap(side)
      if modem.getNamesRemote and not (modem.isWireless and modem.isWireless()) then
        local count, has_computers = 0, false
        for _, name in ipairs(modem.getNamesRemote()) do
          if modem.hasTypeRemote(name, "inventory") then
            count = count + 1
          end
          if modem.hasTypeRemote(name, "computer") then
            has_computers = true
          end
        end
        if count > 0 then
          candidates[#candidates + 1] = { side = side, count = count,
            has_computers = has_computers }
        end
      end
    end
  end
  if #candidates == 0 then
    return {}
  end
  table.sort(candidates, function(a, b)
    if a.has_computers ~= b.has_computers then
      return not a.has_computers
    end
    return a.count > b.count
  end)
  local best = candidates[1]
  return {
    storage_side = best.side,
    is_shared = (modems == 1 or best.has_computers) or nil,
    is_ambiguous = #candidates > 1 or nil,
  }
end

------------------------------------------------------------------------------
-- The node
------------------------------------------------------------------------------

--- Create a node.
-- @tparam table options
--   config   node config (logistics.normalise_node), changed in place
--   save     function() -> true | nil, err
--   sources  from logistics_sources.load
--   log      optional { warn = function(format, ...) }
-- @treturn table node
function logistics_node.new(options)
  local config = logistics.normalise_node(options.config)
  local sources = options.sources
  local log = options.log
  local node = {
    config = config,
    inventories = {}, -- from the last read: { handle, role, source, items?, fill? }
    totals = {},
    sources_read = nil, -- nil until the first read, so tools do not show "no storage"
    sort_paused_until = 0,
    finds = {}, -- [id] = { before, touched, until_clock }: players finding a chest
    holds = {}, -- [crossing] = clock until which ports are left alone
    report_seq = 0,
    -- Changes whenever the node starts, so the controller knows seqs began again.
    boot = os.epoch("utc"),
  }
  local pending_moves = {}

  local function record_move(from, to, item, count)
    -- Blocks the node changed itself are no answer to "which chest did I drop into?".
    for _, find in pairs(node.finds) do
      find.touched[from], find.touched[to] = true, true
    end
    pending_moves[#pending_moves + 1] = { from = from, to = to, item = item, count = count }
    if #pending_moves > logistics_node.MAX_MOVES then
      table.remove(pending_moves, 1)
    end
  end

  function node.save()
    return options.save()
  end

  local function role_of(handle, source)
    local default = source.default_role and source.default_role(handle) or nil
    return logistics.role_of(config, handle, default)
  end

  -- Log each unreadable block once (not every round), and again only after it was
  -- readable in between.
  local failing = {}
  local function log_failures(failures)
    local now_failing = {}
    for _, failure in ipairs(failures) do
      if not failing[failure.handle] and log then
        log.warn("cannot read %s: %s", failure.handle, failure.error)
      end
      now_failing[failure.handle] = true
    end
    failing = now_failing
  end

  --- One round: read every block, then sort the inputs into storage.
  function node.round()
    local totals, blocks, failures, inventories = logistics_sources.read_all(sources, role_of)
    node.inventories, node.totals, node.sources_read = inventories, totals, blocks
    local now = logistics_node.env.clock()
    if now >= node.sort_paused_until then
      local skip_ports = node.ports_held()
      local _, sort_failures = node.lock.exclusive(logistics_sorting.sort_inputs, inventories,
        record_move, skip_ports)
      for _, failure in ipairs(sort_failures) do
        failures[#failures + 1] = failure
      end
    end
    log_failures(failures)
  end

  --- Every block found, with role, label and fill from the last read (no extra calls
  -- to the blocks), plus configured ones that are gone (missing).
  function node.list_storages()
    local rows, seen = {}, {}
    for _, inventory in ipairs(node.inventories) do
      local fill = inventory.fill or {}
      seen[inventory.handle] = true
      local entry = config.storages[inventory.handle]
      rows[#rows + 1] = {
        handle = inventory.handle,
        label = logistics.storage_name(config, inventory.handle),
        role = inventory.role,
        size = fill.size,
        used = fill.used,
        pos = entry and entry.pos,
      }
    end
    -- A re-placed modem gives its chest a new name; the old entry shows up here so it
    -- can be forgotten instead of piling up unseen.
    for handle, entry in pairs(config.storages) do
      if not seen[handle] then
        rows[#rows + 1] = {
          handle = handle,
          label = logistics.storage_name(config, handle),
          role = entry.role or "?",
          is_missing = true,
        }
      end
    end
    table.sort(rows, function(a, b) return a.label < b.label end)
    return rows
  end

  --- What the controller gets each round. Moves are handed over only once. The totals
  -- are a copy: a hub on this computer lowers its own counts after a request.
  function node.report()
    local moves = pending_moves
    pending_moves = {}
    node.report_seq = node.report_seq + 1
    local blocks = node.list_storages()
    local blocks_text = textutils.serialise(blocks, { compact = true })
    local is_due = node.report_seq - (node.blocks_sent_at or -math.huge)
      >= logistics_node.BLOCKS_EVERY
    if blocks_text ~= node.blocks_sent or is_due then
      node.blocks_sent, node.blocks_sent_at = blocks_text, node.report_seq
    else
      blocks = nil -- unchanged: the controller keeps the last list
    end
    local totals = {}
    for item, found in pairs(node.totals) do
      totals[item] = { count = found.count, label = found.label }
    end
    return {
      seq = node.report_seq,
      boot = node.boot,
      totals = totals,
      blocks = blocks,
      moves = moves,
      sources = node.sources_read,
      poll_seconds = config.poll_seconds,
      -- What this node can craft and is crafting (logistics-crafting sets node.crafter).
      crafting = node.crafter and node.crafter.summary() or nil,
    }
  end

  -- Crafting (used on this computer by logistics-crafting; no network) ------

  --- Move items from storage into a machine block (optionally into one slot).
  function node.supply(item, count, machine, slot)
    local result, err = logistics_sorting.supply(node.inventories, item, count, machine,
      record_move, slot)
    if result then
      local found = node.totals[item]
      if found then
        found.count = math.max(0, found.count - result.moved)
      end
    end
    return result, err
  end

  --- What is in a block right now: [item] = count (read live, not from the round).
  function node.contents(handle)
    for _, inventory in ipairs(node.inventories) do
      if inventory.handle == handle and type(inventory.source.list) == "function" then
        local ok, slots = pcall(inventory.source.list, handle)
        if not ok then
          return nil, tostring(slots)
        end
        local items = {}
        for _, stack in pairs(slots) do
          items[stack.name] = (items[stack.name] or 0) + stack.count
        end
        return items
      end
    end
    return nil, "no block called " .. tostring(handle)
  end

  --- Does this node have a recycle block?
  function node.has_recycler()
    for _, inventory in ipairs(node.inventories) do
      if inventory.role == "recycle" then
        return true
      end
    end
    return false
  end

  --- Send items to the recycle block: from a block (a machine's scrap) or storage.
  -- @treturn number Items moved.
  function node.recycle(item, count, from)
    local moved = logistics_sorting.to_recycle(node.inventories, item, count, from,
      record_move) or 0
    if not from then
      local found = node.totals[item]
      if found then
        found.count = math.max(0, found.count - moved)
      end
    end
    return moved
  end

  --- Empty a block into storage.
  function node.retrieve(handle)
    return logistics_sorting.empty_block(node.inventories, handle, record_move)
  end

  --- Stored count of an item (from the last round, lowered by what left since).
  function node.stored(item)
    local found = node.totals[item]
    return found and found.count or 0
  end

  --- The machine blocks of this node.
  function node.machines()
    local list = {}
    for _, inventory in ipairs(node.inventories) do
      if inventory.role == "machine" then
        list[#list + 1] = inventory.handle
      end
    end
    return list
  end

  -- Blocks found now, plus configured ones that are missing (to forget them).
  local function handles()
    local list, seen = {}, {}
    for _, inventory in ipairs(node.inventories) do
      list[#list + 1] = inventory.handle
      seen[inventory.handle] = true
    end
    for handle in pairs(config.storages) do
      if not seen[handle] then
        list[#list + 1] = handle
      end
    end
    return list
  end

  --- Deliver items to an output block (see logistics_sorting.request). The counts drop
  -- at once, so a second request does not see items that already left.
  -- @tparam string item Item id.
  -- @tparam number count
  -- @tparam[opt] string output Handle of the output block; default the first one.
  function node.request(item, count, output)
    local result, err = logistics_sorting.request(node.inventories, item, count, output,
      record_move)
    local found = node.totals[item]
    if result and found then
      found.count = math.max(0, found.count - result.moved)
    end
    if result then
      -- The first report that already counts this move (the hub lowers its own count
      -- only until that report arrives).
      result.seq = node.report_seq + 1
    end
    return result, err
  end

  --- Change a block's role, label or position, or forget a missing one.
  -- @tparam table change { storage (handle or label), role?, label?, pos?, clear_pos?,
  --   forget? }
  function node.set_storage(change)
    local handle, err = logistics.find_storage(config, handles(), change.storage)
    if not handle then
      return nil, err
    end
    if change.forget then
      config.storages[handle] = nil
    else
      local pos = change.pos
      if change.clear_pos then
        pos = false
      end
      local ok, set_error = logistics.set_storage(config, handle, change.role, change.label, pos)
      if not ok then
        return nil, set_error
      end
      for _, inventory in ipairs(node.inventories) do
        if inventory.handle == handle and change.role then
          inventory.role = change.role
        end
      end
    end
    local saved, save_error = node.save()
    if not saved then
      return nil, save_error
    end
    return { storage = handle }
  end

  -- Item totals of every block right now (only for finding a chest).
  local function live_totals()
    local totals = {}
    for _, inventory in ipairs(node.inventories) do
      local source = inventory.source
      if type(source.list) == "function" then
        local ok, slots = pcall(source.list, inventory.handle)
        local total = 0
        for _, stack in pairs(ok and slots or {}) do
          total = total + stack.count
        end
        totals[inventory.handle] = total
      end
    end
    return totals
  end

  --- Find a chest, step 1: pause sorting (so only the player changes chests) and
  -- remember what is in every block.
  -- Sorting stays paused while any search is open (each runs out by itself).
  local function update_pause()
    local latest = 0
    local now = logistics_node.env.clock()
    for id, find in pairs(node.finds) do
      if find.until_clock <= now then
        node.finds[id] = nil
      else
        latest = math.max(latest, find.until_clock)
      end
    end
    node.sort_paused_until = latest
  end

  -- Several players may search at once: each search has its own id and snapshot.
  function node.find_start(id)
    id = id or "local"
    node.finds[id] = {
      before = live_totals(),
      touched = {},
      until_clock = logistics_node.env.clock() + logistics_node.FIND_PAUSE_SECONDS,
    }
    update_pause()
    return true
  end

  --- Find a chest, step 2: the blocks whose contents changed; sorting resumes.
  function node.find_finish(id)
    id = id or "local"
    local find = node.finds[id] or { before = {}, touched = {} }
    local changed = {}
    for handle, total in pairs(live_totals()) do
      local before = find.before[handle]
      if before and before ~= total and not find.touched[handle] then
        changed[#changed + 1] = { handle = handle, label = logistics.storage_name(config, handle) }
      end
    end
    node.finds[id] = nil
    update_pause()
    return changed
  end

  -- Ports ------------------------------------------------------------------

  local function took(item, moved)
    local found = node.totals[item]
    if found then
      found.count = math.max(0, found.count - moved)
    end
  end

  --- Are the ports left alone right now (some crossing still under way)?
  function node.ports_held()
    local now = logistics_node.env.clock()
    for crossing, until_clock in pairs(node.holds) do
      if until_clock > now then
        return true
      end
      node.holds[crossing] = nil
    end
    return false
  end

  --- Leave ports alone for a while: items of one crossing are about to arrive. Each
  -- crossing has its own hold, so one finishing never releases another.
  -- @tparam[opt] number seconds
  -- @tparam[opt] string hold The crossing's name.
  function node.port_hold(seconds, hold)
    local until_clock = logistics_node.env.clock() + (seconds or logistics_node.PORT_HOLD_SECONDS)
    hold = hold or "local"
    node.holds[hold] = math.max(node.holds[hold] or 0, until_clock)
    return true
  end

  --- Move items from storage into a port (the first step of a crossing).
  function node.to_port(item, count, port, hold)
    node.port_hold(nil, hold)
    local result, err = logistics_sorting.to_port(node.inventories, item, count, port, record_move)
    if result then
      took(item, result.moved)
      result.seq = node.report_seq + 1
    end
    return result, err
  end

  --- Move items that arrived in a port on to an output (the last step); this crossing
  -- stops holding the ports (others may still).
  function node.from_port(port, item, count, output, hold)
    local result, err = logistics_sorting.from_port(node.inventories, port, item, count, output,
      record_move)
    node.holds[hold or "local"] = nil
    return result, err
  end

  --- Put one item into a port so the controller can pair it with the main cable.
  function node.push_marker(port)
    node.port_hold(nil, "marker")
    return logistics_sorting.push_marker(node.inventories, port, record_move)
  end

  --- The proxy a hub on this computer uses: the node itself (same functions as the
  -- controller's proxy for a node elsewhere, see logistics_client.NODE_OPS).
  function node.proxy()
    return node
  end

  --- The lone-mode levels for the controller (the node service sets
  -- node.levels_exporter).
  function node.export_levels()
    if not node.levels_exporter then
      return nil, "this node keeps no levels"
    end
    return node.levels_exporter()
  end

  --- Start crafting (the controller asks when a watched item is low).
  function node.craft(item, count)
    if not node.crafter then
      return nil, "this node does not craft (install logistics-crafting)"
    end
    return node.crafter.start(item, count)
  end

  --- Handlers for the controller (protocol "blockos.logistics.node"), built from
  -- logistics_client.NODE_OPS.
  -- @tparam[opt] function is_joined function() -> boolean (default: ask the domain)
  function node.handlers(is_joined)
    return import("logistics_client").node_handlers(node, function(ctx)
      return rpc.require_computer_if_joined(ctx, is_joined)
    end)
  end

  -- Moves take turns (sorting, requests, crossings, crafting supplies): each works on the
  -- chests as they are, not half-way through another's moves. Reading stays outside.
  node.lock = import("lock").new()
  for _, name in ipairs({ "request", "to_port", "from_port", "push_marker", "supply",
    "retrieve", "recycle" }) do
    local move = node[name]
    node[name] = function(...)
      return node.lock.exclusive(move, ...)
    end
  end

  return node
end

return logistics_node
