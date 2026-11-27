--- Request handlers of the domain controller (protocol "blockos.domain").
--
-- Kept apart from the service so tests can call them directly. Permissions:
--   join, leave                   name + password of any domain user (friends only:
--                                 joining is not guarded); leave also takes the
--                                 logged-in user's token
--   login, validate, logout,      a joined computer's token
--   validate_computer, host_update,
--   service_register,             (a computer registers services pointing at itself,
--   service_unregister            and removes only those)
--   resolve, service_find,        anyone
--   list_hosts
--   group_get                     a joined computer or a logged-in user (role info for
--                                 modules: does it exist, is it open to everyone)
--   group_addmember, group_rmmember, group_set_everyone, group_del
--                                 domain-admins, or members of the group's managed_by
--   group_add                     domain-admins, or a module's admins creating
--                                 <module>-... roles managed by themselves
--   computer_config               a joined computer: what it should have installed and set
--   profile_get, profile_set      the logged-in user's own roaming profile
--   list_users, list_groups,      any logged-in domain user (read only)
--   list_computers, list_services,
--   list_computer_roles,
--   dc_status
--   everything else               a domain-admins user token
--
-- Every change first checks that the controller's disk has room to save it.
-- When it does not, the change is refused; reads, logins and lookups go on.
-- @module dc_handlers

local directory = import("directory")
local rpc = import("rpc")

-- Argument schemas of the operations (see wire.validate).
local NAME = { type = "string", max = 32 }
local ARGS = {
  leave = {
    admin_name = { type = "string", optional = true },
    admin_password = { type = "string", optional = true },
  },
  join = { hostname = NAME, admin_name = "string", admin_password = "string" },
  login = { name = "string", password = "string" },
  token = { token = "string" },
  computer_token = { computer_token = "string" },
  host_update = {
    hostname = NAME,
    info = { type = "table", optional = true },
    kind = { type = "string", optional = true },
    version = { type = "string", optional = true },
  },
  hostname = { hostname = NAME },
  service_type = { type = NAME },
  service = { type = NAME, host = NAME, protocol = { type = "string", optional = true } },
  service_register = { type = NAME, protocol = { type = "string", optional = true } },
  name = { name = NAME },
  user_password = { name = NAME, password = "string" },
  user_enable = { name = NAME, is_enabled = "boolean" },
  membership = { group = NAME, user = NAME },
  group_add = {
    name = NAME,
    everyone = { type = "boolean", optional = true },
    managed_by = { type = "string", max = 32, optional = true },
  },
  group_everyone = { group = NAME, everyone = "boolean" },
  group_manager = { group = NAME, managed_by = { type = "string", max = 32, optional = true } },
  computer_role = {
    name = NAME,
    packages = "table",
    settings = { type = "table", optional = true },
  },
  computer_assign = { hostname = NAME, roles = "table" },
  profile_set = {
    apps = { type = "table", optional = true },
    settings = { type = "table", optional = true },
  },
}

local dc_handlers = {}

dc_handlers.DISK_FULL = "the domain controller's disk is full; changes are refused until "
  .. "space is freed"

--- Build the handler table.
-- @tparam Directory dir
-- @tparam table storage
--   save()          write the directory; returns true or nil, err
--   has_room()      true if a save would fit
--   disk_status()   optional: { free, capacity } of the controller's disk
--   save_sessions() optional: persist user sessions
-- @tparam[opt] table clock { now = seconds function, today = day function }
-- @treturn table { [op] = function(request_ctx, args) }
function dc_handlers.new(dir, storage, clock)
  clock = clock or {}
  local now = clock.now or function() return math.floor(os.epoch("utc") / 1000) end
  local today = clock.today or function() return os.day("utc") end
  local handlers = {}

  local function computer_of(ctx)
    return dir:computer_by_token(ctx.computer_token)
  end

  local function require_computer(ctx)
    local hostname = computer_of(ctx)
    if not hostname then
      return nil, "this computer is not a member of the domain"
    end
    return hostname
  end

  local function require_user(ctx, groups)
    local user = dir:validate(ctx.token, now())
    if not user then
      return nil, "login required"
    end
    if not groups then
      return user
    end
    for _, group in ipairs(groups) do
      if dir:is_member(group, user.name) then
        return user
      end
    end
    return nil, "permission denied"
  end

  local function require_admin(ctx)
    return require_user(ctx, { directory.ADMINS })
  end

  -- Make a change only if it can be saved, then save it.
  local function change(operation)
    if not storage.has_room() then
      return nil, dc_handlers.DISK_FULL
    end
    local result, err = operation()
    if not result then
      return nil, err
    end
    local saved, save_error = storage.save()
    if not saved then
      return nil, save_error
    end
    return result
  end

  -- Sessions are saved so logins survive a restart (best effort: a full disk
  -- only means people log in again after the next restart).
  local function save_sessions()
    if storage.save_sessions and storage.has_room() then
      storage.save_sessions()
    end
  end

  local with_args = rpc.with_args

  -- Joining ------------------------------------------------------------------

  handlers.join = with_args(ARGS.join, function(ctx, args)
    if not dir:can_join(args.admin_name, args.admin_password) then
      return nil, "wrong user name or password"
    end
    local token, err = change(function() return dir:join(args.hostname, ctx.sender) end)
    if not token then
      return nil, err
    end
    return { computer_token = token, domain = dir:name() }
  end)

  -- Either a logged-in domain user (their token) or a name and password.
  handlers.leave = with_args(ARGS.leave, function(ctx, args)
    local hostname, err = require_computer(ctx)
    if not hostname then
      return nil, err
    end
    local is_logged_in = dir:validate(ctx.token, now()) ~= nil
    if not is_logged_in and not dir:can_join(args.admin_name, args.admin_password) then
      return nil, "wrong user name or password"
    end
    return change(function() return dir:remove_computer(hostname) end)
  end)

  -- Sessions -----------------------------------------------------------------

  handlers.login = with_args(ARGS.login, function(ctx, args)
    local hostname, err = require_computer(ctx)
    if not hostname then
      return nil, err
    end
    local session, login_error = dir:login(args.name, args.password, now())
    if session then
      save_sessions()
    end
    return session, login_error
  end)

  handlers.validate = with_args(ARGS.token, function(ctx, args)
    local hostname, err = require_computer(ctx)
    if not hostname then
      return nil, err
    end
    local user = dir:validate(args.token, now())
    if not user then
      return nil, "login required"
    end
    return user
  end)

  handlers.logout = with_args(ARGS.token, function(ctx, args)
    local hostname, err = require_computer(ctx)
    if not hostname then
      return nil, err
    end
    dir:logout(args.token)
    save_sessions()
    return true
  end)

  --- Which computer does a computer token belong to? Lets a service check a
  -- request from another system (e.g. a crafter asking a storage computer).
  handlers.validate_computer = with_args(ARGS.computer_token, function(ctx, args)
    local hostname, err = require_computer(ctx)
    if not hostname then
      return nil, err
    end
    local other = dir:computer_by_token(args.computer_token)
    if not other then
      return nil, "unknown computer"
    end
    return { hostname = other }
  end)

  -- Host and service records -------------------------------------------------

  -- Status reports are mostly kept in memory; only a rename, a new computer ID
  -- or the first report of a day is saved. A full disk only skips that save.
  handlers.host_update = with_args(ARGS.host_update, function(ctx, args)
    local hostname, needs_save = dir:update_host(ctx.computer_token, {
      hostname = args.hostname,
      id = ctx.sender,
      info = args.info,
      kind = args.kind,
      version = args.version,
    }, now(), today())
    if not hostname then
      return nil, needs_save
    end
    if needs_save and storage.has_room() then
      storage.save()
    end
    return { hostname = hostname }
  end)

  handlers.resolve = with_args(ARGS.hostname, function(_, args)
    local id = dir:resolve(args.hostname)
    if not id then
      return nil, "unknown host"
    end
    return { id = id }
  end)

  function handlers.list_hosts()
    return dir:list_hosts(now(), today())
  end

  handlers.service_find = with_args(ARGS.service_type, function(_, args)
    local service = dir:find_service(args.type)
    if not service then
      return nil, "no such service record"
    end
    return service
  end)

  --- A computer registers a service record pointing at itself (e.g. `stock`
  -- after `stock setup`), so nobody has to run `domain dns add` by hand.
  handlers.service_register = with_args(ARGS.service_register, function(ctx, args)
    local hostname, err = require_computer(ctx)
    if not hostname then
      return nil, err
    end
    return change(function() return dir:add_service(args.type, hostname, args.protocol) end)
  end)

  --- A computer removes a service record pointing at itself (e.g. the old
  -- `stock` record after `stock rename`). Records of other hosts stay untouched.
  handlers.service_unregister = with_args(ARGS.service_type, function(ctx, args)
    local hostname, err = require_computer(ctx)
    if not hostname then
      return nil, err
    end
    local service = dir:find_service(args.type)
    if not service then
      return nil, "no such service record"
    end
    if service.host ~= hostname then
      return nil, "that service record belongs to " .. service.host
    end
    return change(function() return dir:remove_service(args.type) end)
  end)

  handlers.service_add = with_args(ARGS.service, function(ctx, args)
    local user, err = require_admin(ctx)
    if not user then
      return nil, err
    end
    return change(function() return dir:add_service(args.type, args.host, args.protocol) end)
  end)

  handlers.service_del = with_args(ARGS.service_type, function(ctx, args)
    local user, err = require_admin(ctx)
    if not user then
      return nil, err
    end
    return change(function() return dir:remove_service(args.type) end)
  end)

  -- Directory management -----------------------------------------------------

  local function read_only(list)
    return function(ctx)
      local user, err = require_user(ctx)
      if not user then
        return nil, err
      end
      return list()
    end
  end

  handlers.list_users = read_only(function() return dir:list_users() end)
  handlers.list_groups = read_only(function() return dir:list_groups() end)
  handlers.list_services = read_only(function() return dir:list_services() end)
  handlers.list_computer_roles = read_only(function() return dir:list_computer_roles() end)

  --- What the calling computer should have installed and set (its computer roles merged).
  function handlers.computer_config(ctx)
    local hostname, err = require_computer(ctx)
    if not hostname then
      return nil, err
    end
    return dir:computer_config(hostname)
  end
  handlers.list_computers = read_only(function() return dir:list_hosts(now(), today()) end)

  --- Health of the controller: counts, saved size and disk space.
  handlers.dc_status = read_only(function()
    local status = dir:stats()
    status.domain = dir:name()
    status.has_room = storage.has_room()
    if storage.disk_status then
      local disk = storage.disk_status()
      status.free = disk.free
      status.capacity = disk.capacity
    end
    return status
  end)

  -- Admin-only operations: op name -> { argument schema, the change }.
  local admin_operations = {
    user_add = { ARGS.user_password, function(args)
      return dir:add_user(args.name, args.password)
    end },
    user_del = { ARGS.name, function(args)
      return dir:remove_user(args.name)
    end },
    user_enable = { ARGS.user_enable, function(args)
      return dir:set_enabled(args.name, args.is_enabled)
    end },
    group_set_manager = { ARGS.group_manager, function(args)
      return dir:set_manager(args.group, args.managed_by)
    end },
    computer_role_set = { ARGS.computer_role, function(args)
      return dir:set_computer_role(args.name, args.packages, args.settings)
    end },
    computer_role_del = { ARGS.name, function(args)
      return dir:remove_computer_role(args.name)
    end },
    computer_assign = { ARGS.computer_assign, function(args)
      return dir:assign_computer_roles(args.hostname, args.roles)
    end },
    computer_remove = { ARGS.hostname, function(args)
      return dir:remove_computer(args.hostname)
    end },
  }
  for op, operation in pairs(admin_operations) do
    local schema, apply = operation[1], operation[2]
    handlers[op] = with_args(schema, function(ctx, args)
      local user, err = require_admin(ctx)
      if not user then
        return nil, err
      end
      return change(function() return apply(args) end)
    end)
  end

  -- Groups and module roles -------------------------------------------------

  --- Role info for modules (any joined computer or logged-in user): whether the role
  -- exists (the module is set up) and whether it is open to everyone.
  handlers.group_get = with_args(ARGS.name, function(ctx, args)
    if not computer_of(ctx) and not dir:validate(ctx.token, now()) then
      return nil, "this computer is not a member of the domain"
    end
    local info = dir:group_info(args.name)
    if not info then
      return nil, "no such group"
    end
    return info
  end)

  -- A change to one group by a domain admin or one of the group's managers.
  local function manager_change(ctx, group, apply)
    local user, err = require_user(ctx)
    if not user then
      return nil, err
    end
    if not dir:can_manage(group, user.name) then
      return nil, "permission denied"
    end
    return change(apply)
  end

  handlers.group_add = with_args(ARGS.group_add, function(ctx, args)
    local user, err = require_user(ctx)
    if not user then
      return nil, err
    end
    if not dir:can_create(args.name, args.managed_by, user.name) then
      return nil, "permission denied"
    end
    return change(function()
      return dir:add_group(args.name, { everyone = args.everyone, managed_by = args.managed_by })
    end)
  end)

  handlers.group_del = with_args(ARGS.name, function(ctx, args)
    return manager_change(ctx, args.name, function() return dir:remove_group(args.name) end)
  end)

  handlers.group_addmember = with_args(ARGS.membership, function(ctx, args)
    return manager_change(ctx, args.group, function()
      return dir:add_member(args.group, args.user)
    end)
  end)

  handlers.group_rmmember = with_args(ARGS.membership, function(ctx, args)
    return manager_change(ctx, args.group, function()
      return dir:remove_member(args.group, args.user)
    end)
  end)

  handlers.group_set_everyone = with_args(ARGS.group_everyone, function(ctx, args)
    return manager_change(ctx, args.group, function()
      return dir:set_everyone(args.group, args.everyone)
    end)
  end)

  -- Roaming profiles: each user reads and changes only their own.
  function handlers.profile_get(ctx)
    local user, err = require_user(ctx)
    if not user then
      return nil, err
    end
    return dir:get_profile(user.name)
  end

  handlers.profile_set = with_args(ARGS.profile_set, function(ctx, args)
    local user, err = require_user(ctx)
    if not user then
      return nil, err
    end
    return change(function() return dir:set_profile(user.name, args) end)
  end)

  -- Users may change their own password; admins may change anyone's.
  handlers.user_passwd = with_args(ARGS.user_password, function(ctx, args)
    local user, err = require_user(ctx)
    if not user then
      return nil, err
    end
    if user.name ~= args.name and not dir:is_member(directory.ADMINS, user.name) then
      return nil, "permission denied"
    end
    return change(function() return dir:set_password(args.name, args.password) end)
  end)

  return handlers
end

return dc_handlers
