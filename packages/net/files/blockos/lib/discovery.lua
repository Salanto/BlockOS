--- Finding and advertising services (a package server, a logistics controller, ...).
--
-- In a domain a service is a record on the controller (`domain.register_service`):
-- one direct question, no broadcast. Without a domain it is a rednet name hosted
-- under the service's protocol (`rednet.host`), found with `rednet.lookup`, which is
-- a broadcast and a 2 s wait. Answers are cached for CACHE_SECONDS either way; a
-- caller whose service stopped answering calls discovery.forget to look again.
-- @module discovery

local rpc = import("rpc")

local discovery = {}

discovery.CACHE_SECONDS = 60

--- Clock (tests replace it).
discovery.env = {
  clock = function() return os.clock() end,
}

local cache = {} -- [service_type] = { id, label, at }

local function joined_domain()
  local found, domain = pcall(import, "domain")
  if found and domain.is_joined() then
    return domain
  end
  return nil
end

--- Find a service.
-- @tparam string service_type e.g. "pkg", "logistics-kitchen"
-- @tparam string protocol The protocol it serves (and hosts its rednet name under).
-- @tparam[opt] table options { rednet_name = name it hosts (default: any) }
-- @treturn[1] number Computer ID.
-- @treturn[1] string What to call it (host name).
-- @treturn[2] nil
function discovery.find(service_type, protocol, options)
  local now = discovery.env.clock()
  local hit = cache[service_type]
  if hit and now - hit.at < discovery.CACHE_SECONDS then
    return hit.id, hit.label
  end
  local id, label = nil, nil
  local domain = joined_domain()
  if domain then
    local service = domain.find_service(service_type)
    if service then
      id, label = service.id, service.host
    end
  end
  if not id then
    local rednet_name = options and options.rednet_name
    id = rpc.find(protocol, rednet_name)
    label = id and (rednet_name or ("#" .. id)) or nil
  end
  if id then
    cache[service_type] = { id = id, label = label, at = now }
  end
  return id, label
end

--- Forget a cached answer (the service stopped answering, or moved).
-- @tparam[opt] string service_type nil forgets everything
function discovery.forget(service_type)
  if service_type then
    cache[service_type] = nil
  else
    cache = {}
  end
end

--- Advertise a service running on this computer: its rednet name (works without a
-- domain) and, in a domain, its service record.
-- @tparam string service_type
-- @tparam string protocol
-- @tparam[opt] string rednet_name Name to host (default: the service type).
-- @treturn[1] true
-- @treturn[2] nil
-- @treturn[2] string why the domain record could not be registered
function discovery.advertise(service_type, protocol, rednet_name)
  if rednet.isOpen() then
    pcall(rednet.host, protocol, rednet_name or service_type)
  end
  local domain = joined_domain()
  if domain then
    return domain.register_service(service_type, protocol)
  end
  return true
end

return discovery
