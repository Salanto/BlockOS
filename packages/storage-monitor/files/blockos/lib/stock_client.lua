--- Talking to a stock computer, from the `stock` tool or a board.
--
-- On the stock computer itself the handlers are called directly; a local
-- administrator there always counts as an admin (so a broken access list can
-- be fixed at the keyboard). Elsewhere the stock computer is found through the
-- domain service record "stock" (or "stock-<name>") and called over rpc.
-- @module stock_client

local rpc = import("rpc")

local stock_client = {}

stock_client.PROTOCOL = "blockos.stock"
stock_client.CONFIG_FILE = "etc/blockos/storage-monitor"

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
-- @treturn[1] table connection { is_local, describe, call(op, args) }
-- @treturn[2] nil
-- @treturn[2] string error message
function stock_client.connect(name)
  local server = blockos and blockos.stock_server
  if server and (name == nil or name == server.config.name) then
    return local_connection(server)
  end

  local found_domain, domain = pcall(import, "domain")
  if not found_domain or not domain.is_joined() then
    return nil, "this computer is not in a domain"
  end
  local service = domain.find_service(stock_client.service_type(name))
  if not service then
    return nil, "no stock computer found; run 'stock setup' on it first"
  end
  return {
    is_local = false,
    describe = service.host,
    call = function(op, args)
      return rpc.call(service.id, stock_client.PROTOCOL, op, args)
    end,
  }
end

return stock_client
