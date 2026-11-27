-- logistics-controller service: merges the nodes' reports into one catalog, routes
-- requests to the node that can deliver, runs the levels (limits, alarms) and answers
-- players' tools, boards and programs (protocol "blockos.logistics").
--
-- Nodes find it through the domain service record "logistics" (or
-- "logistics-<name>"), else by its rednet name; they report every round. A node that
-- stops reporting is shown as stale, never forgotten automatically.
--
-- Items cross between nodes through ports on a wired main cable (logistics_ports):
-- ports are paired automatically when a node gives a chest the "port" role.

local function config_path()
  return import("paths").top(import("logistics_client").CONTROLLER_FILE)
end

-- How the controller acts on a node elsewhere. A retry is safe (rpc runs a request
-- once), so a lost answer neither moves items twice nor fails a move that happened.
local function remote_proxy(rpc, id, protocol)
  local function call(op, args, timeout)
    return rpc.call(id, protocol, op, args, { retries = 1, timeout = timeout or 5 })
  end
  return {
    id = id,
    request = function(item, count, output)
      return call("request", { item = item, count = count, output = output }, 12)
    end,
    set_storage = function(change) return call("set_storage", change) end,
    find_start = function(search) return call("find_start", { id = search }) end,
    find_finish = function(search) return call("find_finish", { id = search }) end,
    export_levels = function() return call("export_levels") end,
    port_hold = function(seconds, hold)
      return call("port_hold", { seconds = seconds, hold = hold })
    end,
    to_port = function(item, count, port, hold)
      return call("to_port", { item = item, count = count, port = port, hold = hold }, 12)
    end,
    from_port = function(port, item, count, output, hold)
      return call("from_port", { port = port, item = item, count = count, output = output,
        hold = hold }, 12)
    end,
    push_marker = function(port) return call("push_marker", { port = port }) end,
    craft = function(item, count) return call("craft", { item = item, count = count }) end,
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
  local logistics_ports = import("logistics_ports")
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
  -- Slow work (pairing a port, asking a node to craft) runs in its own loop, not in
  -- the one receiving reports: waiting for an rpc answer there swallows other nodes'
  -- reports.
  local WORK_EVENT = "logistics_controller_work"
  local work = {}
  local function defer(job)
    work[#work + 1] = job
    os.queueEvent(WORK_EVENT)
  end
  local function work_loop()
    while true do
      local job = table.remove(work, 1)
      if job then
        local done, job_error = pcall(job)
        if not done then
          log.warn("controller work failed: %s", tostring(job_error))
        end
      else
        os.pullEvent(WORK_EVENT)
      end
    end
  end

  local ports = logistics_ports.new(config, save)
  local hub = logistics_hub.new({
    config = config,
    save = save,
    defer = defer,
    transfer = ports.transfer,
    port_status = ports.status,
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
  -- A node on this same computer hands its reports over directly (no rednet).
  blockos.logistics_controller = hub

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
    if not hub.nodes[name] then
      -- The same computer under a new name: a rename, not a second node.
      for old, known in pairs(hub.nodes) do
        if known.proxy.id == sender and hub.rename_node(old, name) then
          ports.rename_node(old, name)
          log.info("node %s is now called %s", old, name)
          break
        end
      end
    end
    local entry = hub.nodes[name]
    if entry and entry.proxy.id ~= sender then
      log.info("node %s now reports from computer #%d", name, sender)
    end
    local proxy = (entry and entry.proxy.id == sender) and entry.proxy
      or remote_proxy(rpc, sender, logistics_client.NODE_PROTOCOL)
    hub.update(name, event.data, proxy)
    for _, handle in ipairs(ports.check(name, hub.nodes[name].report.blocks)) do
      defer(function()
        local main, err = ports.pair(name, handle, proxy)
        if main then
          log.info("port %s/%s is %s on the main cable", name, handle, main)
        else
          log.warn("pairing port %s/%s: %s", name, handle, tostring(err))
        end
      end)
    end
  end

  local ok, err = pcall(parallel.waitForAny,
    function() rpc.serve(logistics_client.PROTOCOL, handlers) end,
    work_loop,
    function()
      -- Levels held back by the 2 s limit are checked here.
      while true do
        sleep(logistics_hub.LEVELS_SECONDS)
        hub.check_levels_if_due()
      end
    end,
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
  blockos.logistics_controller = nil
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
