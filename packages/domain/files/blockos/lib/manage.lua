--- Remote admin: what a domain admin can do on a joined computer from dsa (protocol
-- "blockos.manage"): see its health, reboot it, update it now, control services, read
-- its log, and open a remote shell (see remote_shell.lua). Domain admins only, checked
-- with the domain controller on every request.
-- @module manage

local rpc = import("rpc")

local manage = {}

manage.PROTOCOL = "blockos.manage"
manage.ADMINS = "domain-admins"
manage.UPDATE_NOW_EVENT = "blockos_update_now"
manage.MAX_LOG_LINES = 40

--- Argument schemas (see wire.validate).
manage.ARGS = {
  service = { name = { type = "string", max = 32 }, action = { type = "string", max = 8 } },
  log = { lines = { type = "number", min = 1, optional = true } },
  shell_open = { width = { type = "number", min = 10 }, height = { type = "number", min = 5 } },
}

--- The computer's parts (tests replace these).
manage.env = {
  services = function() return blockos.services end,
  reboot = function() os.reboot() end,
  queue = function(...) os.queueEvent(...) end,
  log_tail = function(count) return import("log").tail(count) end,
  disk = function()
    return { free = fs.getFreeSpace("/"), capacity = fs.getCapacity and fs.getCapacity("/") }
  end,
  installed = function() return import("pkg").installed() end,
}

--- What dsa shows about a computer.
-- @treturn table { hostname, kind, version, uptime, user, services, failed, disk, packages,
--   fuel?, position?, notices }
function manage.status()
  local services, failed = {}, 0
  for _, service in ipairs(manage.env.services().list()) do
    services[#services + 1] = {
      name = service.name,
      state = service.state,
      last_error = service.last_error,
    }
    if service.state == "failed" or service.state == "crashed" then
      failed = failed + 1
    end
  end
  local packages = {}
  for name, entry in pairs(manage.env.installed()) do
    packages[name] = entry.version
  end
  local net = blockos and blockos.net
  local info = net and net.build_announce and net.build_announce().data.info or {}
  local notices = {}
  for _, notice in pairs(blockos and blockos.notices or {}) do
    notices[#notices + 1] = notice
  end
  table.sort(notices)
  return {
    hostname = net and net.hostname() or ("#" .. os.getComputerID()),
    kind = blockos and blockos.device and blockos.device.kind() or "computer",
    version = blockos and blockos.version or "?",
    uptime = math.floor(os.clock()),
    user = blockos and blockos.user and blockos.user.name or nil,
    services = services,
    failed = failed,
    disk = manage.env.disk(),
    packages = packages,
    fuel = info.fuel,
    position = info.position,
    notices = notices,
  }
end

--- Build the handler table. `shells` (from remote_shell) opens remote shell sessions.
-- @tparam[opt] table shells { open(ctx, user, width, height) -> { session } }
-- @treturn table
function manage.handlers(shells)
  local handlers = {}

  local function require_admin(ctx)
    return rpc.require_user(ctx, { manage.ADMINS })
  end

  local function admin(fn)
    return function(ctx, args)
      local user, err = require_admin(ctx)
      if not user then
        return nil, err
      end
      return fn(ctx, args or {}, user)
    end
  end

  handlers.status = admin(function()
    return manage.status()
  end)

  --- Answer first, then reboot a moment later (the reply must leave before we go).
  handlers.reboot = admin(function()
    manage.env.queue("blockos_manage_reboot")
    return { rebooting = true }
  end)

  --- Check roles and updates now and apply them even if someone is logged in.
  handlers.update = admin(function()
    manage.env.queue(manage.UPDATE_NOW_EVENT)
    return { checking = true }
  end)

  handlers.service = rpc.with_args(manage.ARGS.service, admin(function(_, args)
    local services = manage.env.services()
    if args.action ~= "start" and args.action ~= "stop" and args.action ~= "restart" then
      return nil, "the action must be start, stop or restart"
    end
    local ok, err = services[args.action](args.name)
    if not ok then
      return nil, err
    end
    return { state = services.state(args.name) }
  end))

  handlers.log = rpc.with_args(manage.ARGS.log, admin(function(_, args)
    return manage.env.log_tail(math.min(args.lines or 20, manage.MAX_LOG_LINES))
  end))

  handlers.shell_open = rpc.with_args(manage.ARGS.shell_open, admin(function(ctx, args, user)
    if not shells then
      return nil, "remote shells are not available here"
    end
    return shells.open(ctx, user, math.floor(args.width), math.floor(args.height))
  end))

  return handlers
end

return manage
