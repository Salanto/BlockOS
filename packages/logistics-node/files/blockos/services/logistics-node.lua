-- logistics-node service: reads this node's storage network every round, sorts input
-- chests into storage, and reports to the controller.
--
-- Setup asks nothing: on the first start the storage modem is the wired modem that
-- sees inventories (it is closed for rednet, see net.close_side), and an old
-- storage-monitor config is taken over (chest roles and labels here, levels kept for
-- lone mode).
--
-- Lone mode: until a controller is found, the node runs a hub over itself, so its own
-- terminal can use `logistics` (catalog, requests, levels, map). Once a controller has
-- been found the node stays its node, and its levels can be moved over with
-- `logistics levels import <node>` on the controller.

-- Rounds between looking for a controller while none is known (lookups cost ~2 s),
-- and between checks that it has not moved to another computer.
local DISCOVER_ROUNDS = 6
local RECHECK_ROUNDS = 30

local function file(name)
  return import("paths").top(import("logistics_client")[name])
end

-- Rename a file out of the way, replacing an older copy with that name.
local function set_aside(path, suffix)
  if fs.exists(path .. suffix) then
    fs.delete(path .. suffix)
  end
  fs.move(path, path .. suffix)
end

-- First start: take over an old storage-monitor config, find the storage modem.
local function first_setup(fsx, logistics, logistics_node, log)
  local node_config, levels
  local old_path = file("OLD_FILE")
  local old = fs.exists(old_path) and fsx.read_table(old_path)
  if old then
    node_config, levels = logistics.split_old_config(old)
    fsx.write_table(file("LEVELS_FILE"), levels)
    set_aside(old_path, ".migrated")
    log.info("took over the storage-monitor config (levels kept for lone mode)")
  else
    node_config = logistics.normalise_node({})
  end
  local sides = logistics_node.detect_sides()
  node_config.storage_side = sides.storage_side
  node_config.is_shared = sides.is_shared
  if sides.storage_side and not sides.is_shared then
    import("net").close_side(sides.storage_side)
    log.info("storage modem: %s (closed for rednet)", sides.storage_side)
  elseif sides.storage_side then
    log.warn("the storage modem on %s is the only modem: it carries rednet too",
      sides.storage_side)
  end
  if sides.is_ambiguous then
    log.warn("several modems see chests; picked %s (change: logistics node side)",
      sides.storage_side)
  end
  fsx.write_table(file("NODE_FILE"), node_config)
  return node_config
end

local function run(ctx)
  local fsx = import("fsx")
  local rpc = import("rpc")
  local wire = import("wire")
  local logistics = import("logistics")
  local logistics_client = import("logistics_client")
  local logistics_handlers = import("logistics_handlers")
  local logistics_hub = import("logistics_hub")
  local logistics_node = import("logistics_node")
  local logistics_scope = import("logistics_scope")
  local logistics_sources = import("logistics_sources")
  local log = ctx.log

  local node_path = file("NODE_FILE")
  local config = fs.exists(node_path) and fsx.read_table(node_path)
    or first_setup(fsx, logistics, logistics_node, log)
  config = logistics.normalise_node(config)

  -- Sources only see the storage network (and blocks against the computer).
  local scope = logistics_scope.new(config.storage_side)
  local sources = logistics_sources.load()
  for _, source in ipairs(sources) do
    if source.peripheral ~= nil then
      source.peripheral = scope
    end
  end

  local function save()
    if pcall(fsx.write_table, node_path, config) then
      return true
    end
    return nil, "could not save the node config (is the disk full?)"
  end
  local node = logistics_node.new({ config = config, save = save, sources = sources, log = log })
  blockos.logistics_node = node

  local function hostname()
    return blockos.net and blockos.net.hostname() or ("#" .. os.getComputerID())
  end

  -- Lone mode -------------------------------------------------------------

  local levels_path = file("LEVELS_FILE")
  local hub = nil

  local function start_hub()
    local levels = fs.exists(levels_path) and fsx.read_table(levels_path) or {}
    hub = logistics_hub.new({
      config = levels,
      save = function()
        if pcall(fsx.write_table, levels_path, levels) then
          return true
        end
        return nil, "could not save the levels (is the disk full?)"
      end,
      hostname = hostname(),
      title = "Logistics " .. hostname(),
    })
    logistics_hub.env.log = log.warn
    blockos.logistics_hub = {
      hub = hub,
      handlers = logistics_handlers.new(hub),
      config = hub.config,
      describe = hostname() .. " (no controller)",
    }
  end

  local function stop_hub()
    if hub then
      hub.stop()
      hub = nil
      blockos.logistics_hub = nil
    end
  end

  -- The levels this node kept in lone mode, handed over once to the controller.
  local function export_levels()
    if not fs.exists(levels_path) then
      return nil, "this node has no levels to hand over"
    end
    local levels = fsx.read_table(levels_path)
    set_aside(levels_path, ".imported")
    if blockos.notices then
      blockos.notices.logistics_levels = nil
    end
    return levels
  end

  -- The controller -------------------------------------------------------

  local controller_id = nil
  local rounds_since_lookup = DISCOVER_ROUNDS

  local function on_controller_found(id, label)
    controller_id = id
    if config.controller == nil then
      config.controller = label
      save()
      stop_hub()
      log.info("controller found: %s; this node now reports to it", tostring(label))
      if fs.exists(levels_path) and blockos.notices then
        blockos.notices.logistics_levels = "This node's alarms can move to the controller: "
          .. "run 'logistics levels import " .. hostname() .. "' there"
      end
    end
  end

  local function look_for_controller()
    rounds_since_lookup = rounds_since_lookup + 1
    if rounds_since_lookup < (controller_id and RECHECK_ROUNDS or DISCOVER_ROUNDS) then
      return
    end
    rounds_since_lookup = 0
    local id, label = logistics_client.find_server()
    if id and id ~= os.getComputerID() then
      on_controller_found(id, label)
    end
  end

  local function send_report()
    local report = node.report()
    report.node = hostname()
    if controller_id then
      rednet.send(controller_id, wire.event(logistics_client.REPORT_TOPIC, report),
        logistics_client.NODE_PROTOCOL)
    elseif hub then
      hub.update(report.node, report, node.proxy())
    end
  end

  if config.controller == nil then
    start_hub()
  end

  -- Be findable for `logistics levels import` and the controller's requests.
  if rednet.isOpen() then
    pcall(rednet.host, logistics_client.NODE_PROTOCOL, hostname())
  end

  local ok, err = pcall(parallel.waitForAny,
    function() rpc.serve(logistics_client.NODE_PROTOCOL, node.handlers(export_levels)) end,
    function()
      while true do
        node.round()
        look_for_controller()
        send_report()
        sleep(config.poll_seconds)
      end
    end
  )
  stop_hub()
  blockos.logistics_node = nil
  if not ok then
    error(err, 0)
  end
end

return {
  name = "logistics-node",
  description = "Reads and sorts this node's storage and reports to the controller",
  after = { "net", "domain-client" },
  restart = "on-failure",
  run = run,
}
