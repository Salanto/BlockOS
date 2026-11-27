-- logistics-controller service: merges the nodes' reports into one catalog, routes
-- requests to the node that can deliver, runs the levels (limits, alarms) and answers
-- players' tools, boards and programs (protocol "blockos.logistics").
--
-- Nodes find it through the domain service record "logistics" (or
-- "logistics-<name>"), else by its rednet name; they report every round. A node that
-- stops reporting is shown as stale, never forgotten automatically.

local function config_path()
  return import("paths").top(import("logistics_client").CONTROLLER_FILE)
end

-- How the controller acts on a node elsewhere. Never retried: a lost answer must not
-- move items twice.
local function remote_proxy(rpc, id, protocol)
  local function call(op, args, timeout)
    return rpc.call(id, protocol, op, args, { retries = 0, timeout = timeout or 5 })
  end
  return {
    id = id,
    request = function(item, count, output)
      return call("request", { item = item, count = count, output = output }, 12)
    end,
    set_storage = function(change) return call("set_storage", change) end,
    find_start = function() return call("find_start") end,
    find_finish = function() return call("find_finish") end,
    export_levels = function() return call("export_levels") end,
  }
end

-- Take over a node's lone-mode levels: limits and refill targets. Alarm outputs are
-- left out: they named the node's own sides and relays.
local function merge_levels(config, levels)
  local added = 0
  for item, watch in pairs(levels.watches or {}) do
    if not config.watches[item] then
      config.watches[item] = {
        label = watch.label,
        limit = watch.limit,
        refill_to = watch.refill_to,
        outputs = {},
      }
      added = added + 1
    end
  end
  return added
end

local function run(ctx)
  local fsx = import("fsx")
  local rpc = import("rpc")
  local wire = import("wire")
  local logistics = import("logistics")
  local logistics_client = import("logistics_client")
  local logistics_handlers = import("logistics_handlers")
  local logistics_hub = import("logistics_hub")
  local log = ctx.log

  local path = config_path()
  local config = logistics.normalise(fs.exists(path) and fsx.read_table(path) or {})
  local function save()
    if pcall(fsx.write_table, path, config) then
      return true
    end
    return nil, "could not save the controller config (is the disk full?)"
  end
  if not fs.exists(path) then
    save()
  end

  local hostname = blockos.net and blockos.net.hostname() or ("#" .. os.getComputerID())
  local hub = logistics_hub.new({
    config = config,
    save = save,
    hostname = hostname,
    title = "Logistics" .. (config.name and (" " .. config.name) or ""),
  })
  logistics_hub.env.log = log.warn

  local handlers, require_admin = logistics_handlers.new(hub)

  --- Move a node's lone-mode levels to the controller (once).
  handlers.import_levels = rpc.with_args({ node = { type = "string", max = 32 } },
    function(request_ctx, args)
      local ok, err = require_admin(request_ctx)
      if not ok then
        return nil, err
      end
      local entry = hub.nodes[args.node]
      if not entry then
        return nil, "no node called " .. args.node .. " has reported yet"
      end
      local levels, export_error = entry.proxy.export_levels()
      if not levels then
        return nil, export_error
      end
      local added = merge_levels(config, levels)
      local saved, save_error = save()
      if not saved then
        return nil, save_error
      end
      hub.check_levels()
      return { added = added }
    end)

  blockos.logistics_hub = {
    hub = hub,
    handlers = handlers,
    config = config,
    describe = hostname,
  }

  -- Be findable: by rednet name (works without a domain) and, in a domain, as the
  -- "logistics" (or "logistics-<name>") service record.
  local service_type = logistics_client.service_type(config.name)
  if rednet.isOpen() then
    pcall(rednet.host, logistics_client.PROTOCOL, service_type)
  end
  local found, domain = pcall(import, "domain")
  if found and domain.is_joined() then
    local registered, err = domain.register_service(service_type, logistics_client.PROTOCOL)
    if not registered then
      log.warn("could not register the %s service record: %s", service_type, tostring(err))
    end
  end

  local function on_report(sender, message)
    local event = wire.parse(message, "event", logistics_client.REPORT_SCHEMA)
    if not event or event.topic ~= logistics_client.REPORT_TOPIC then
      return
    end
    local name = event.data.node
    local entry = hub.nodes[name]
    if entry and entry.proxy.id ~= sender then
      log.info("node %s now reports from computer #%d", name, sender)
    end
    local proxy = (entry and entry.proxy.id == sender) and entry.proxy
      or remote_proxy(rpc, sender, logistics_client.NODE_PROTOCOL)
    hub.update(name, event.data, proxy)
  end

  local ok, err = pcall(parallel.waitForAny,
    function() rpc.serve(logistics_client.PROTOCOL, handlers) end,
    function()
      while true do
        local _, sender, message, protocol = os.pullEvent("rednet_message")
        if protocol == logistics_client.NODE_PROTOCOL then
          on_report(sender, message)
        end
      end
    end
  )
  hub.stop()
  blockos.logistics_hub = nil
  if not ok then
    error(err, 0)
  end
end

return {
  name = "logistics-controller",
  description = "Merges the logistics nodes, routes requests and runs the levels",
  after = { "net", "domain-client" },
  restart = "on-failure",
  run = run,
}
