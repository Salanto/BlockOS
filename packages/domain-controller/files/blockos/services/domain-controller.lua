-- domain-controller service: serves the domain directory over rednet.
--
-- The directory is saved to /etc/blockos/directory after every change. User
-- sessions are kept in memory only: if the controller reloads, users log in
-- again. Only runs once `dcpromo` has created the domain.

local DIRECTORY_FILE = "etc/blockos/directory"

local function directory_path()
  return import("paths").top(DIRECTORY_FILE)
end

local function run(ctx)
  local dc_handlers = import("dc_handlers")
  local directory = import("directory")
  local fsx = import("fsx")
  local rpc = import("rpc")

  local data = fsx.read_table(directory_path())
  if not data then
    error("the directory file is missing or unreadable", 0)
  end
  local dir = directory.load(data)

  local function save()
    fsx.write_table(directory_path(), dir.data)
  end

  -- The controller can check user tokens itself, without a network round trip.
  rpc.set_computer_validator(function(computer_token)
    local hostname = dir:computer_by_token(computer_token)
    return hostname and { hostname = hostname }
  end)
  rpc.set_user_validator(function(token)
    return dir:validate(token, os.clock())
  end)

  -- Hosting under the domain name lets computers find us with rednet.lookup.
  if rednet.isOpen() then
    rednet.host("blockos.domain", dir:name())
  end
  ctx.log.info("serving domain %s", dir:name())
  rpc.serve("blockos.domain", dc_handlers.new(dir, save))
end

return {
  name = "domain-controller",
  description = "Domain directory: users, groups, computers, names and services",
  after = { "net" },
  restart = "on-failure",
  condition = function() return fs.exists(directory_path()) end,
  run = run,
}
