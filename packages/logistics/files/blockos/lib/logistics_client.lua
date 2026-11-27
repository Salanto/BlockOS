--- Talking to the logistics hub, from the `logistics` tool, a board or a program.
--
-- The hub is the controller, found through the domain service record "logistics" (or
-- "logistics-<name>"), or by its rednet name when there is no domain. On a node without
-- a controller (lone mode), or on the controller itself, the local hub's handlers are
-- called directly; a local administrator there always counts as an admin, so a broken
-- role can be fixed at the keyboard.
-- @module logistics_client

local config = import("config")
local rpc = import("rpc")

local logistics_client = {}

logistics_client.PROTOCOL = "blockos.logistics"
logistics_client.NODE_PROTOCOL = "blockos.logistics.node"
logistics_client.CONTROLLER_FILE = "etc/blockos/logistics-controller"
logistics_client.NODE_FILE = "etc/blockos/logistics-node"
logistics_client.LEVELS_FILE = "etc/blockos/logistics-levels"
--- The storage-monitor config of older versions (migrated by the node).
logistics_client.OLD_FILE = "etc/blockos/storage-monitor"
--- A node's report to the controller (protocol NODE_PROTOCOL, see logistics_node).
logistics_client.REPORT_TOPIC = "report"
logistics_client.REPORT_SCHEMA = {
  node = { type = "string", max = 32 },
  totals = "table",
  blocks = "table",
  moves = { type = "table", optional = true },
  sources = { type = "number", optional = true },
  poll_seconds = { type = "number", optional = true },
  pos = { type = "table", optional = true },
  crafting = { type = "table", optional = true }, -- { recipes = {item...}, jobs = {...} }
}

--- Operations that move items or wait for every node: not retried, longer timeout.
logistics_client.SLOW_OPS = { request = true, find_start = true, find_finish = true, craft = true }
logistics_client.SLOW_TIMEOUT = 15

config.define("blockos.logistics.server", {
  description = "Which logistics controller this computer uses (its name); empty: the default.",
  type = "string",
  roams = true, -- a domain user's profile may choose it (profile set ...)
})
config.define("blockos.logistics.board", {
  description = "Monitor or Create Display Link that shows the logistics board.",
  type = "string",
})
config.define("blockos.logistics.board_style", {
  description = "Board on a monitor: auto (the wall when it fits, else the list), wall or list.",
  default = "auto",
  type = "string",
})
config.define("blockos.logistics.reactions", {
  description = "Redstone outputs that are on while an item is low: { { item, target, side } }.",
  default = {},
  type = "table",
})

--- The service record type of a controller.
-- @tparam[opt] string name e.g. "kitchen"
-- @treturn string "logistics" or "logistics-kitchen"
function logistics_client.service_type(name)
  if name then
    return "logistics-" .. name
  end
  return "logistics"
end

local function is_local_admin()
  local user = blockos and blockos.user
  return user ~= nil and user.source == "local" and user.is_admin == true
end

--- A connection that calls handlers in this computer directly.
-- @tparam table handlers
-- @tparam string describe
-- @treturn table connection
function logistics_client.local_connection(handlers, describe)
  local connection = { is_local = true, describe = describe or "this computer" }
  function connection.call(op, args)
    local handler = handlers[op]
    if not handler then
      return nil, "unknown operation: " .. op
    end
    local ctx = {
      sender = os.getComputerID(),
      token = blockos.user and blockos.user.token,
      local_admin = is_local_admin(),
    }
    local ok, result, err = pcall(handler, ctx, args or {})
    if not ok then
      return nil, tostring(result)
    end
    return result, err
  end
  return connection
end

--- Find the controller.
-- @tparam[opt] string name Which one, when there are several (default: the
--   blockos.logistics.server setting).
-- @treturn[1] number Computer ID.
-- @treturn[1] string What to call it.
-- @treturn[2] nil
function logistics_client.find_server(name)
  name = name or config.get("blockos.logistics.server")
  if name == "" then
    name = nil
  end
  local service_type = logistics_client.service_type(name)
  local found_domain, domain = pcall(import, "domain")
  if found_domain and domain.is_joined() then
    local service = domain.find_service(service_type)
    if service then
      return service.id, service.host
    end
  end
  local id = rpc.find(logistics_client.PROTOCOL, service_type)
  if id then
    return id, service_type
  end
  return nil
end

--- Connect to the hub.
-- @tparam[opt] string name Which controller, when there are several.
-- @tparam[opt] table options { interactive = true } for programs: an expired
--   login then asks for the password once instead of failing.
-- @treturn[1] table connection { is_local, describe, call(op, args) }
-- @treturn[2] nil
-- @treturn[2] string error message
function logistics_client.connect(name, options)
  local hub = blockos and blockos.logistics_hub
  if hub and (name == nil or name == hub.config.name) then
    return logistics_client.local_connection(hub.handlers, hub.describe)
  end
  local server_id, label = logistics_client.find_server(name)
  if not server_id then
    return nil, "no logistics controller found (install logistics-controller on a computer)"
  end
  local relogin = options and options.interactive
  return {
    is_local = false,
    describe = label,
    call = function(op, args)
      -- A request is never retried (a lost answer must not deliver twice), and the
      -- controller waits for the node, which moves items a tick per stack.
      local call_options = { relogin = relogin }
      if logistics_client.SLOW_OPS[op] then
        call_options.retries, call_options.timeout = 0, logistics_client.SLOW_TIMEOUT
      end
      return rpc.call(server_id, logistics_client.PROTOCOL, op, args, call_options)
    end,
  }
end

return logistics_client
