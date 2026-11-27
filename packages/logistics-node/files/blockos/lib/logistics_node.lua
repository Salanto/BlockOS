--- A logistics node: one computer per storage network. Every round it reads its
-- blocks, sorts its input chests into storage and reports to the controller; on the
-- controller's request it delivers items, changes block roles and helps find a chest.
--
-- Nodes exist so that many computers each count a small network in parallel: every
-- inventory read costs a game tick, so one computer reading a whole base is slow.
--
-- Protocol "blockos.logistics.node" (wire):
--   node -> controller  event "report" { node, totals, blocks, moves, sources,
--                       poll_seconds } (full state each round, so it corrects itself)
--   controller -> node  rpc request { item, count, output? }, set_storage { storage,
--                       role?, label?, pos?, clear_pos?, forget? }, find_start, find_finish,
--                       export_levels
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
--- Sorting pauses while someone finds a chest, at most this long.
logistics_node.FIND_PAUSE_SECONDS = 60


local ARGS = {
  request = {
    item = { type = "string", max = 128 },
    count = { type = "number", min = 1 },
    output = { type = "string", optional = true, max = 64 },
  },
  set_storage = {
    storage = { type = "string", max = 64 },
    role = { type = "string", optional = true, max = 16 },
    label = { type = "string", optional = true, max = 64 },
    pos = { type = "table", optional = true },
    clear_pos = { type = "boolean", optional = true },
    forget = { type = "boolean", optional = true },
  },
}

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
--   the most is picked; `logistics node side` changes it)
function logistics_node.detect_sides(api)
  api = api or peripheral
  local modems, candidates = 0, {}
  for _, side in ipairs(logistics.SIDES) do
    if api.isPresent(side) and api.hasType(side, "modem") then
      modems = modems + 1
      local modem = api.wrap(side)
      if modem.getNamesRemote and not (modem.isWireless and modem.isWireless()) then
        local count = 0
        for _, name in ipairs(modem.getNamesRemote()) do
          if modem.hasTypeRemote(name, "inventory") then
            count = count + 1
          end
        end
        if count > 0 then
          candidates[#candidates + 1] = { side = side, count = count }
        end
      end
    end
  end
  if #candidates == 0 then
    return {}
  end
  table.sort(candidates, function(a, b) return a.count > b.count end)
  return {
    storage_side = candidates[1].side,
    is_shared = modems == 1 or nil,
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
  }
  local pending_moves = {}

  local function record_move(from, to, item, count)
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
    if logistics_node.env.clock() >= node.sort_paused_until then
      local _, sort_failures = logistics_sorting.sort_inputs(inventories, record_move)
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

  --- What the controller gets each round. Moves are handed over only once.
  function node.report()
    local moves = pending_moves
    pending_moves = {}
    return {
      totals = node.totals,
      blocks = node.list_storages(),
      moves = moves,
      sources = node.sources_read,
      poll_seconds = config.poll_seconds,
    }
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
  function node.find_start()
    node.sort_paused_until = logistics_node.env.clock() + logistics_node.FIND_PAUSE_SECONDS
    node.find_before = live_totals()
    return true
  end

  --- Find a chest, step 2: the blocks whose contents changed; sorting resumes.
  function node.find_finish()
    local before = node.find_before or {}
    local changed = {}
    for handle, total in pairs(live_totals()) do
      if before[handle] and before[handle] ~= total then
        changed[#changed + 1] = { handle = handle, label = logistics.storage_name(config, handle) }
      end
    end
    node.find_before = nil
    node.sort_paused_until = 0
    return changed
  end

  --- The proxy a hub on this computer uses (lone mode).
  function node.proxy()
    return {
      request = node.request,
      set_storage = node.set_storage,
      find_start = node.find_start,
      find_finish = node.find_finish,
    }
  end

  --- Handlers for the controller (protocol "blockos.logistics.node").
  -- @tparam[opt] function export_levels function() -> levels | nil, err (lone-mode
  --   levels this node kept, for `logistics levels import` on the controller)
  -- @tparam[opt] function is_joined function() -> boolean (default: ask the domain)
  function node.handlers(export_levels, is_joined)
    is_joined = is_joined or function()
      local found, domain = pcall(import, "domain")
      return found and domain.is_joined()
    end
    local function allowed(ctx)
      if ctx.local_admin or not is_joined() then
        return true
      end
      return rpc.require_computer(ctx)
    end
    local function guarded(fn)
      return function(ctx, args)
        local ok, err = allowed(ctx)
        if not ok then
          return nil, err
        end
        return fn(args or {})
      end
    end
    return {
      request = rpc.with_args(ARGS.request, guarded(function(args)
        return node.request(args.item, math.floor(args.count), args.output)
      end)),
      set_storage = rpc.with_args(ARGS.set_storage, guarded(node.set_storage)),
      find_start = guarded(node.find_start),
      find_finish = guarded(node.find_finish),
      export_levels = guarded(function()
        if not export_levels then
          return nil, "this node keeps no levels"
        end
        return export_levels()
      end),
    }
  end

  return node
end

return logistics_node
