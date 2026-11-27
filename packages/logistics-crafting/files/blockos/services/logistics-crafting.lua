-- logistics-crafting service: runs crafting jobs on this logistics node's machines.
--
-- It talks to the logistics-node service on this computer directly, so watching the
-- machines costs no network traffic. The controller asks for a craft when a watched
-- item runs low (it sees this node's recipes in its reports); missing ingredients are
-- asked from the controller once per step and arrive through the ports.

local RECIPES_FILE = "etc/blockos/logistics-recipes"
local GROUPS_FILE = "etc/blockos/logistics-machine-groups"

local function run(ctx)
  local fsx = import("fsx")
  local rpc = import("rpc")
  local logistics_client = import("logistics_client")
  local logistics_crafter = import("logistics_crafter")
  local path = import("paths").top(RECIPES_FILE)
  local groups_path = import("paths").top(GROUPS_FILE)

  -- The node service starts first; wait until it provides its node.
  local services = import("services")
  local node = services.await("logistics.node")

  local recipes = fs.exists(path) and fsx.read_table(path) or {}
  local groups = fs.exists(groups_path) and fsx.read_table(groups_path) or {}
  local function save()
    if pcall(fsx.write_table, path, recipes) and pcall(fsx.write_table, groups_path, groups) then
      return true
    end
    return nil, "could not save the recipes (is the disk full?)"
  end

  -- An ingredient this node lacks: the controller carries it from another node
  -- straight into the machine (a retry is safe: rpc runs a request once).
  local function fetch(item, count, machine)
    if not node.controller_id then
      return nil, "no controller to bring it from another node"
    end
    local hostname = blockos.net and blockos.net.hostname() or ("#" .. os.getComputerID())
    return rpc.call(node.controller_id, logistics_client.PROTOCOL, "supply",
      { node = hostname, item = item, count = count, target = machine },
      { retries = 1, timeout = 30 })
  end

  local crafter = logistics_crafter.new({
    node = node,
    recipes = recipes,
    groups = groups,
    save = save,
    fetch = fetch,
    log = ctx.log,
  })
  node.crafter = crafter
  ctx.provide("logistics.crafter", crafter)

  local ok, err = pcall(function()
    while true do
      -- The node service restarted: start over with its new node (a restart of this
      -- service; running jobs are asked for again by the controller).
      if services.get("logistics.node") ~= node then
        error("the logistics node restarted", 0)
      end
      crafter.tick()
      sleep(1)
    end
  end)
  if node.crafter == crafter then
    node.crafter = nil
  end
  if not ok then
    error(err, 0)
  end
end

return {
  name = "logistics-crafting",
  description = "Runs crafting jobs on this node's machines",
  after = { "logistics-node" },
  restart = "on-failure",
  run = run,
}
