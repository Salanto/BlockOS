--- Package source backed by a BlockOS package server (protocol "blockos.pkg").
--
-- Implements the same interface as the sources in pkg.lua (describe, index,
-- fetch), so `pkg` and `update` can install from a server like from a disk.
-- @module pkg_remote

local config = import("config")
local rpc = import("rpc")

local pkg_remote = {}

pkg_remote.PROTOCOL = "blockos.pkg"
pkg_remote.SERVICE_TYPE = "pkg"

local FETCH_TIMEOUT = 10

config.define("blockos.pkg.server", {
  description = "Package server to use by default (hostname). Empty: GitHub releases.",
  type = "string",
})

--- A source reading from the package server with this computer ID.
-- @tparam number server_id
-- @tparam[opt] string label Name shown to the user.
-- @treturn table
function pkg_remote.source(server_id, label)
  local source = {}

  function source.describe()
    return "package server " .. (label or ("#" .. server_id))
  end

  function source.index()
    return rpc.call(server_id, pkg_remote.PROTOCOL, "index")
  end

  function source.fetch(name)
    return rpc.call(server_id, pkg_remote.PROTOCOL, "fetch", { name = name },
      { timeout = FETCH_TIMEOUT })
  end

  return source
end

--- Find a package server.
--
-- With a name, it is resolved like any hostname. Without one, the domain's
-- "pkg" service record is used, then the blockos.pkg.server setting.
-- @tparam[opt] string name
-- @treturn[1] number Computer ID.
-- @treturn[1] string Label for messages.
-- @treturn[2] nil
-- @treturn[2] string error message
function pkg_remote.find_server(name)
  local net = blockos and blockos.net
  if not net then
    return nil, "the net service is not running"
  end
  name = name or config.get("blockos.pkg.server")
  if name and name ~= "" then
    local id = net.resolve(name)
    if not id then
      return nil, "cannot find package server " .. name
    end
    return id, name
  end

  local ok, domain = pcall(import, "domain")
  if ok and domain.is_joined() then
    local service = domain.find_service(pkg_remote.SERVICE_TYPE)
    if service then
      return service.id, service.host
    end
  end
  return nil, "no package server known: register one with 'domain dns add pkg <host>' "
    .. "or set blockos.pkg.server"
end

--- Upload a package file to a server (needs a domain admin login).
-- @tparam number server_id
-- @tparam string raw The .pkg file contents.
function pkg_remote.publish(server_id, raw)
  return rpc.call(server_id, pkg_remote.PROTOCOL, "publish", { raw = raw },
    { timeout = FETCH_TIMEOUT })
end

return pkg_remote
