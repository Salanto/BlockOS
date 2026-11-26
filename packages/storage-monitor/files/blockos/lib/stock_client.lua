--- Talking to a stock computer, from the `stock` tool or a board.
--
-- On the stock computer itself the handlers are called directly; a local
-- administrator there always counts as an admin (so a broken access list can
-- be fixed at the keyboard). Elsewhere the stock computer is found through the
-- domain service record "stock" (or "stock-<name>"), or by its rednet name when
-- there is no domain, and called over rpc.
-- @module stock_client

local config = import("config")
local rpc = import("rpc")

local stock_client = {}

stock_client.PROTOCOL = "blockos.stock"
stock_client.CONFIG_FILE = "etc/blockos/storage-monitor"

config.define("blockos.stock.server", {
  description = "Which stock computer this one talks to (its --name); empty: the default.",
  type = "string",
})
config.define("blockos.stock.board", {
  description = "Monitor or Create Display Link that shows the stock board.",
  type = "string",
})
config.define("blockos.stock.reactions", {
  description = "Redstone outputs that are on while an item is low: { { item, target, side } }.",
  default = {},
  type = "table",
})

--- The service record type of a stock computer.
-- @tparam[opt] string name e.g. "kitchen"
-- @treturn string "stock" or "stock-kitchen"
function stock_client.service_type(name)
  if name then
    return "stock-" .. name
  end
  return "stock"
end

local function is_local_admin()
  local user = blockos and blockos.user
  return user ~= nil and user.source == "local" and user.is_admin == true
end

local function local_connection(server)
  local connection = { is_local = true, describe = "this computer" }
  function connection.call(op, args)
    local handler = server.handlers[op]
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

--- Connect to a stock computer.
-- @tparam[opt] string name Which one, when there are several.
-- @tparam[opt] table options { interactive = true } for programs: an expired
--   login then asks for the password once instead of failing.
-- @treturn[1] table connection { is_local, describe, call(op, args) }
-- @treturn[2] nil
-- @treturn[2] string error message
function stock_client.connect(name, options)
  local server = blockos and blockos.stock_server
  if server and (name == nil or name == server.config.name) then
    return local_connection(server)
  end

  -- In a domain, ask the controller; otherwise look the stock computer up by
  -- its rednet name.
  local service_type = stock_client.service_type(name)
  local server_id, label = nil, service_type
  local found_domain, domain = pcall(import, "domain")
  if found_domain and domain.is_joined() then
    local service = domain.find_service(service_type)
    if service then
      server_id, label = service.id, service.host
    end
  end
  server_id = server_id or rpc.find(stock_client.PROTOCOL, service_type)
  if not server_id then
    return nil, "no stock computer found; run 'stock setup' on it first"
  end
  local call_options = { relogin = options and options.interactive }
  return {
    is_local = false,
    describe = label,
    call = function(op, args)
      return rpc.call(server_id, stock_client.PROTOCOL, op, args, call_options)
    end,
  }
end

return stock_client
