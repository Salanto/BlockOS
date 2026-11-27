--- Directory management: users, groups, module roles, computer roles, routing, profiles.
-- Part of the domain controller's handlers (see dc_handlers): attached when they are made.
-- @module dc_admin

local directory = import("directory")

local dc_admin = {}

--- Add this part's handlers.
-- @tparam table handlers
-- @tparam table internal What dc_handlers shares with its parts.
function dc_admin.attach(handlers, internal)
  local dir = internal.dir
  local storage = internal.storage
  local ARGS = internal.args
  local now = internal.now
  local today = internal.today
  local with_args = internal.with_args
  local computer_of = internal.computer_of
  local require_computer = internal.require_computer
  local require_user = internal.require_user
  local require_admin = internal.require_admin
  local change = internal.change

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

  -- A mail server asks where a message goes (recipients and their computers).
  handlers.route = with_args(ARGS.route, function(ctx, args)
    local hostname, err = require_computer(ctx)
    if not hostname then
      return nil, err
    end
    return dir:route(args.to, now())
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
end

return dc_admin
