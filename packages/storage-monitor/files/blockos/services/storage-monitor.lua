-- storage-monitor service: reads the stock in attached storage, compares it
-- with the watched limits, raises alarms (redstone, speaker, network alerts)
-- and answers the `stock` tool and boards over rpc. Only runs on a computer
-- where `stock setup` was done.

local MAX_ALERTS = 20

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
  local stock_sources = import("stock_sources")
  local log = ctx.log

  local path = config_path()
  local config = stock.normalise(assert(fsx.read_table(path), "the stock config is unreadable"))
  local sources = stock_sources.load()

  local monitor = { config = config, totals = {}, states = {}, alerts = {}, sources = 0 }

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

  local handlers = stock_handlers.new(monitor)
  blockos.stock_server = { handlers = handlers, monitor = monitor, config = config }

  local applied_outputs = {}
  local function check_stock()
    local totals, blocks = stock_sources.read_all(sources)
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
    for _, alert in ipairs(sent) do
      monitor.alerts[#monitor.alerts + 1] = alert
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

  parallel.waitForAny(
    function() rpc.serve(import("stock_client").PROTOCOL, handlers) end,
    function()
      while true do
        check_stock()
        sleep(config.poll_seconds)
      end
    end
  )
end

return {
  name = "storage-monitor",
  description = "Watches stock and raises alarms when items run low",
  after = { "net", "domain-client" },
  restart = "on-failure",
  condition = function() return fs.exists(config_path()) end,
  run = run,
}
