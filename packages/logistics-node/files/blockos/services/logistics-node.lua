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
-- `logistics levels import <node>` on the controller. When the controller cannot be
-- found three times in a row (or after `logistics node alone`), the node is alone
-- again. A controller on this same computer gets the reports directly.

-- Rounds between looking for a controller while none is known (lookups cost ~2 s),
-- and between checks that it has not moved to another computer.
local DISCOVER_ROUNDS = 6
local RECHECK_ROUNDS = 30
-- Lookups in a row that find no controller before a remote node is alone again.
local LOST_LOOKUPS = 3
-- Rounds between GPS fixes (the wall board groups nodes by height; ~5 min).
local GPS_ROUNDS = 30

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
  -- Programs and logistics-crafting find this node here (withdrawn when it stops).
  ctx.provide("logistics.node", node)
  local services = import("services")

  local function hostname()
    return import("net").self_name()
  end

  -- Lone mode -------------------------------------------------------------

  local levels_path = file("LEVELS_FILE")
  local hub, hub_entry = nil, nil

  local function start_hub()
    if services.get("logistics.controller") then
      return -- a controller runs on this computer: it is the hub
    end
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
      raise_alert = import("alerts").raise,
      title = "Logistics " .. hostname(),
      log = log.warn,
    })
    hub_entry = {
      hub = hub,
      handlers = logistics_handlers.new(hub),
      config = hub.config,
      describe = hostname() .. " (no controller)",
    }
    ctx.provide("logistics.hub", hub_entry)
  end

  local function stop_hub()
    if hub then
      hub.stop()
      ctx.withdraw("logistics.hub", hub_entry)
      hub_entry = nil
      hub = nil
    end
  end

  -- The levels this node kept in lone mode, handed over once to the controller.
  local function export_levels()
    if not fs.exists(levels_path) then
      return nil, "this node has no levels to hand over"
    end
    local levels = fsx.read_table(levels_path)
    set_aside(levels_path, ".imported")
    import("notices").clear("logistics_levels")
    return levels
  end

  -- The controller: one explicit mode ------------------------------------
  --
  --   here    a hub on this computer gets the reports directly: the controller, when
  --           the logistics-controller package runs here, else this node's own hub
  --           (serving only this terminal, so a single node works alone; also while
  --           it looks for a controller it knew before)
  --   remote  reports go to the controller on another computer (controller_id)
  -- enter() is the only place that changes the mode; it sets the hub, the controller id
  -- and the report target together.

  local mode = nil
  local controller_id = nil
  local rounds_since_lookup = DISCOVER_ROUNDS
  local missed_lookups = 0

  local function enter(new_mode, id, label)
    local local_controller = services.get("logistics.controller")
    if new_mode == "here" then
      controller_id = nil
      if local_controller then
        stop_hub()
        -- logistics-crafting asks for missing ingredients by rpc to this computer.
        node.controller_id = os.getComputerID()
      else
        start_hub()
        node.controller_id = nil
      end
    else
      stop_hub()
      controller_id, node.controller_id = id, id
    end
    local remembered = (new_mode == "remote" and label)
      or (local_controller and "local") or config.controller
    if remembered ~= config.controller then
      config.controller = remembered
      save()
    end
    local has_controller = new_mode == "remote" or local_controller ~= nil
    if has_controller and fs.exists(levels_path) then
      import("notices").set("logistics_levels", "This node's alarms can move to the "
        .. "controller: run 'logistics levels import " .. hostname() .. "' there")
    end
    if mode ~= new_mode then
      log.info("logistics mode: %s -> %s%s", tostring(mode), new_mode,
        label and (" (" .. tostring(label) .. ")") or "")
    end
    mode = new_mode
    missed_lookups = 0
  end
  node.mode = function() return mode end

  --- Alone again (the controller is gone for good, or `logistics node alone`).
  function node.go_alone()
    config.controller = nil
    save()
    enter("here")
  end

  local function look_for_controller()
    -- A controller started or stopped on this computer: the hub here changes owner.
    local has_local = services.get("logistics.controller") ~= nil
    local owns_hub = hub ~= nil
    if mode == "here" and has_local == owns_hub then
      enter("here")
    end
    if has_local then
      if mode ~= "here" then
        enter("here")
      end
      return
    end
    rounds_since_lookup = rounds_since_lookup + 1
    if rounds_since_lookup < (mode == "remote" and RECHECK_ROUNDS or DISCOVER_ROUNDS) then
      return
    end
    rounds_since_lookup = 0
    local id, label = logistics_client.find_server(nil, true)
    if id and id ~= os.getComputerID() then
      if mode ~= "remote" or id ~= controller_id then
        enter("remote", id, label)
      end
      missed_lookups = 0
    elseif mode == "remote" then
      missed_lookups = missed_lookups + 1
      if missed_lookups >= LOST_LOOKUPS then
        enter("here")
      end
    end
  end

  -- No storage modem at the first start (the cable came later): keep looking, and
  -- start over with the scoped view once one shows up.
  local rounds_since_detect = 0
  local function redetect()
    if config.storage_side then
      return
    end
    rounds_since_detect = rounds_since_detect + 1
    if rounds_since_detect < DISCOVER_ROUNDS then
      return
    end
    rounds_since_detect = 0
    local sides = logistics_node.detect_sides()
    if sides.storage_side then
      config.storage_side, config.is_shared = sides.storage_side, sides.is_shared
      if not sides.is_shared then
        import("net").close_side(sides.storage_side)
      end
      save()
      error("found the storage modem on " .. sides.storage_side .. "; starting over", 0)
    end
  end

  -- Where this node stands, when GPS hosts are in range (nil otherwise).
  local position = nil
  local rounds_since_gps = GPS_ROUNDS
  local function locate()
    rounds_since_gps = rounds_since_gps + 1
    if rounds_since_gps < GPS_ROUNDS then
      return
    end
    rounds_since_gps = 0
    position = import("net").position() or position
  end

  local function send_report()
    local report = node.report()
    report.node = hostname()
    report.pos = position
    local local_controller = services.get("logistics.controller")
    if mode == "here" and local_controller then
      local_controller.update(report.node, report, node.proxy())
    elseif mode == "remote" then
      local event, err = logistics_client.report_event(report)
      if event then
        rednet.send(controller_id, event, logistics_client.NODE_PROTOCOL)
      else
        log.warn("report not sent: %s", tostring(err))
      end
    elseif hub then
      hub.update(report.node, report, node.proxy())
    end
    local too_big = node.report_too_big()
    if too_big then
      -- A problem (it goes out as an alert); its text stays the same while the size
      -- changes, so it is not reported again every round.
      local limit_kb = math.floor(logistics_node.REPORT_WARN_BYTES / 1024)
      import("notices").set("logistics_report", "This node reports over " .. limit_kb
        .. " KB of items every round: split it into smaller nodes", "warn")
    else
      import("notices").clear("logistics_report")
    end
  end

  -- Start with the hub here; a controller elsewhere is looked up on the first round.
  enter("here")
  node.levels_exporter = export_levels

  -- Be findable for `logistics levels import` and the controller's requests.
  if rednet.isOpen() then
    pcall(rednet.host, logistics_client.NODE_PROTOCOL, hostname())
  end

  local ok, err = pcall(parallel.waitForAny,
    function() rpc.serve(logistics_client.NODE_PROTOCOL, node.handlers()) end,
    function()
      while true do
        node.round()
        locate()
        look_for_controller()
        redetect()
        send_report()
        sleep(config.poll_seconds)
      end
    end
  )
  stop_hub()
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
