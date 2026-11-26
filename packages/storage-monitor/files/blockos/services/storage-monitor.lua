-- storage-monitor service: reads the stock in attached storage, compares it
-- with the watched limits, raises alarms (redstone, speaker, network alerts),
-- empties input chests into storage, delivers requested items to output
-- chests, and answers the `stock` tool and boards over rpc. Only runs on a computer
-- where `stock setup` was done.

local MAX_ALERTS = 20
-- Recent item moves, for the network map's animations.
local MAX_MOVES = 50
-- Sorting pauses while someone finds a chest, at most this long.
local FIND_PAUSE_SECONDS = 60

local function config_path()
  return import("paths").top(import("stock_client").CONFIG_FILE)
end

-- Who gets alerts: everyone (the default), or the IDs of the listed computers.
local function alert_recipients(config, stock, stock_alarms)
  if stock.is_open(config.access.computers) then
    return stock_alarms.EVERYONE
  end
  local ids = {}
  local net = blockos.net
  for _, hostname in ipairs(config.access.computers) do
    local id = net and net.resolve(hostname)
    if id and id ~= os.getComputerID() then
      ids[#ids + 1] = id
    end
  end
  return ids
end

local function run(ctx)
  local fsx = import("fsx")
  local rpc = import("rpc")
  local stock = import("stock")
  local stock_alarms = import("stock_alarms")
  local stock_handlers = import("stock_handlers")
  local stock_logistics = import("stock_logistics")
  local stock_sources = import("stock_sources")
  local log = ctx.log

  local path = config_path()
  local config = stock.normalise(assert(fsx.read_table(path), "the stock config is unreadable"))
  local sources = stock_sources.load()

  -- sources stays nil until the first read, so tools do not show "no storage"
  -- in the moment after a start.
  local monitor = {
    config = config,
    totals = {},
    states = {},
    alerts = {},
    sources = nil,
    inventories = {}, -- from the last read: { handle, role, source, items?, fill? }
    moves = {}, -- recent moves, oldest first: { seq, from, to, item, label, count }
    move_seq = 0,
    -- Changes whenever the service starts, so maps notice that seqs began again.
    move_log = os.epoch("utc"),
    sort_paused_until = 0,
  }

  -- Note a move for the map (the map asks for moves newer than a seq).
  local function record_move(from, to, item, count)
    monitor.move_seq = monitor.move_seq + 1
    local found = monitor.totals[item]
    monitor.moves[#monitor.moves + 1] = {
      seq = monitor.move_seq,
      from = from,
      to = to,
      item = item,
      label = found and found.label or item,
      count = count,
    }
    if #monitor.moves > MAX_MOVES then
      table.remove(monitor.moves, 1)
    end
  end

  function monitor.save()
    if pcall(fsx.write_table, path, config) then
      return true
    end
    return nil, "could not save the stock config (is the disk full?)"
  end

  function monitor.snapshot()
    return {
      title = "Stock" .. (config.name and (" " .. config.name) or ""),
      updated = monitor.updated,
      rows = stock.sorted_rows(monitor.states),
      sources = monitor.sources,
    }
  end

  monitor.list_outputs = stock_alarms.list_outputs

  --- Deliver items to an output chest (see stock_logistics.request).
  -- The counts drop at once, so the Catalog and a second request do not see
  -- items that already left (the next read corrects any difference).
  function monitor.request(item, count, output)
    local result, err = stock_logistics.request(monitor.inventories, item, count, output,
      record_move)
    local found = monitor.totals[item]
    if result and found then
      found.count = math.max(0, found.count - result.moved)
    end
    return result, err
  end

  --- Every inventory found, with role, label and fill from the last read (no
  -- extra calls to the blocks), plus configured ones that are gone (missing).
  function monitor.list_storages()
    local rows, seen = {}, {}
    for _, inventory in ipairs(monitor.inventories) do
      local fill = inventory.fill or {}
      seen[inventory.handle] = true
      rows[#rows + 1] = {
        handle = inventory.handle,
        label = stock.storage_name(config, inventory.handle),
        role = inventory.role,
        size = fill.size,
        used = fill.used,
      }
    end
    -- A re-placed modem gives its chest a new name; the old entry shows up
    -- here so it can be forgotten instead of piling up unseen.
    for handle, entry in pairs(config.storages) do
      if not seen[handle] then
        rows[#rows + 1] = {
          handle = handle,
          label = stock.storage_name(config, handle),
          role = entry.role or "?",
          is_missing = true,
        }
      end
    end
    table.sort(rows, function(a, b) return a.label < b.label end)
    return rows
  end

  -- Item totals of every block right now (only for finding a chest).
  local function live_totals()
    local totals = {}
    for _, inventory in ipairs(monitor.inventories) do
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

  --- Find a chest, step 1: pause sorting (so only the player changes chests)
  -- and remember what is in every block.
  function monitor.find_start()
    monitor.sort_paused_until = os.clock() + FIND_PAUSE_SECONDS
    monitor.find_before = live_totals()
    return true
  end

  --- Find a chest, step 2: the blocks whose contents changed; sorting resumes.
  function monitor.find_finish()
    local before = monitor.find_before or {}
    local changed = {}
    for handle, total in pairs(live_totals()) do
      if before[handle] and before[handle] ~= total then
        changed[#changed + 1] = { handle = handle, label = stock.storage_name(config, handle) }
      end
    end
    monitor.find_before = nil
    monitor.sort_paused_until = 0
    return changed
  end

  local handlers = stock_handlers.new(monitor)
  blockos.stock_server = { handlers = handlers, monitor = monitor, config = config }

  -- Log each unreadable block once (not every poll), and again only after it
  -- was readable in between.
  local failing = {} -- [handle] = true while it fails
  local function log_failures(failures)
    local now_failing = {}
    for _, failure in ipairs(failures) do
      if not failing[failure.handle] then
        log.warn("cannot read %s: %s", failure.handle, failure.error)
      end
      now_failing[failure.handle] = true
    end
    failing = now_failing
  end

  local function role_of(handle, source)
    local default = source.default_role and source.default_role(handle) or nil
    return stock.role_of(config, handle, default)
  end

  local applied_outputs = {}
  local function check_stock()
    local totals, blocks, failures, inventories = stock_sources.read_all(sources, role_of)
    monitor.inventories = inventories
    if os.clock() >= monitor.sort_paused_until then
      local _, sort_failures = stock_logistics.sort_inputs(inventories, record_move)
      for _, failure in ipairs(sort_failures) do
        failures[#failures + 1] = failure
      end
    end
    log_failures(failures)
    monitor.totals, monitor.sources = totals, blocks
    local states, changes = stock.evaluate(config, totals, monitor.states)
    monitor.states = states
    monitor.updated = textutils.formatTime(os.time(), true)

    local wanted_outputs = stock.output_states(config, states)
    applied_outputs = stock_alarms.apply_redstone(wanted_outputs, applied_outputs)
    for _, item in ipairs(changes.went_low) do
      log.warn("%s is low: %d of %d", states[item].label, states[item].count, states[item].limit)
    end
    if #changes.went_low > 0 and config.chime then
      stock_alarms.chime(config.sound)
    end

    local hostname = blockos.net and blockos.net.hostname() or ("#" .. os.getComputerID())
    local recipients = alert_recipients(config, stock, stock_alarms)
    local sent = stock_alarms.send_alerts(hostname, states, changes, recipients)
    local time = textutils.formatTime(os.time(), true)
    for _, alert in ipairs(sent) do
      -- The history shows when it happened (in-game time); not sent on the wire.
      local entry = { time = time }
      for key, value in pairs(alert) do
        entry[key] = value
      end
      monitor.alerts[#monitor.alerts + 1] = entry
      if #monitor.alerts > MAX_ALERTS then
        table.remove(monitor.alerts, 1)
      end
    end
  end

  log.info("watching %d items from %d sources", (function()
    local count = 0
    for _ in pairs(config.watches) do
      count = count + 1
    end
    return count
  end)(), #sources)

  -- Be findable: by rednet name (works without a domain) and, in a domain, as
  -- the "stock" (or "stock-<name>") service record.
  local stock_client = import("stock_client")
  local service_type = stock_client.service_type(config.name)
  if rednet.isOpen() then
    pcall(rednet.host, stock_client.PROTOCOL, service_type)
  end
  local found, domain = pcall(import, "domain")
  if found and domain.is_joined() then
    local ok, err = domain.register_service(service_type, stock_client.PROTOCOL)
    if not ok then
      log.warn("could not register the %s service record: %s", service_type, tostring(err))
    end
  end

  local ok, err = pcall(parallel.waitForAny,
    function() rpc.serve(import("stock_client").PROTOCOL, handlers) end,
    function()
      while true do
        check_stock()
        sleep(config.poll_seconds)
      end
    end
  )
  -- Nobody is counting any more: switch lamps and farms off rather than leave
  -- them as they were. A restart switches the right ones on again.
  blockos.stock_server = nil
  stock_alarms.apply_redstone({}, applied_outputs)
  if not ok then
    error(err, 0)
  end
end

return {
  name = "storage-monitor",
  description = "Watches stock and raises alarms when items run low",
  after = { "net", "domain-client" },
  restart = "on-failure",
  condition = function() return fs.exists(config_path()) end,
  run = run,
}
