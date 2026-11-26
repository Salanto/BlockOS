--- Request handlers of the domain controller (protocol "blockos.domain").
--
-- Kept apart from the service so tests can call them directly. Permissions:
--   join, leave                   name + password of a domain admin or computer-joiner
--   login, validate, logout,      a joined computer's token
--   validate_computer, host_update
--   resolve, service_find,        anyone
--   list_hosts
--   list_users, list_groups,      any logged-in domain user (read only)
--   list_computers, list_services
--   everything else               a domain-admins user token
--                                 (service records: also dns-admins)
-- @module dc_handlers

local directory = import("directory")

local dc_handlers = {}

--- Build the handler table.
-- @tparam Directory dir
-- @tparam function save Called after every change that must be persisted.
-- @tparam[opt] function now Current time in seconds (default os.clock).
-- @treturn table { [op] = function(request_ctx, args) }
function dc_handlers.new(dir, save, now)
  now = now or os.clock
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

  local function require_dns_admin(ctx)
    return require_user(ctx, { directory.ADMINS, directory.DNS_ADMINS })
  end

  -- Run a change and save it if it worked.
  local function change(ok, err)
    if ok then
      save()
    end
    return ok, err
  end

  local function args_table(args)
    if type(args) == "table" then
      return args
    end
    return {}
  end

  -- Joining ------------------------------------------------------------------

  function handlers.join(ctx, args)
    args = args_table(args)
    if not dir:can_join(args.admin_name, args.admin_password) then
      return nil, "only domain-admins or computer-joiners can join computers"
    end
    local token, err = dir:join(args.hostname, ctx.sender)
    if not token then
      return nil, err
    end
    save()
    return { computer_token = token, domain = dir:name() }
  end

  function handlers.leave(ctx, args)
    args = args_table(args)
    local hostname, err = require_computer(ctx)
    if not hostname then
      return nil, err
    end
    if not dir:can_join(args.admin_name, args.admin_password) then
      return nil, "only domain-admins or computer-joiners can remove computers"
    end
    return change(dir:remove_computer(hostname))
  end

  -- Sessions -----------------------------------------------------------------

  function handlers.login(ctx, args)
    args = args_table(args)
    local hostname, err = require_computer(ctx)
    if not hostname then
      return nil, err
    end
    return dir:login(args.name, args.password, now())
  end

  function handlers.validate(ctx, args)
    local hostname, err = require_computer(ctx)
    if not hostname then
      return nil, err
    end
    local user = dir:validate(args_table(args).token, now())
    if not user then
      return nil, "login required"
    end
    return user
  end

  function handlers.logout(ctx, args)
    local hostname, err = require_computer(ctx)
    if not hostname then
      return nil, err
    end
    return dir:logout(args_table(args).token)
  end

  --- Which computer does a computer token belong to? Lets a service check a
  -- request from another system (e.g. a crafter asking a storage computer).
  function handlers.validate_computer(ctx, args)
    local hostname, err = require_computer(ctx)
    if not hostname then
      return nil, err
    end
    local other = dir:computer_by_token(args_table(args).computer_token)
    if not other then
      return nil, "unknown computer"
    end
    return { hostname = other }
  end

  -- Host and service records -------------------------------------------------

  function handlers.host_update(ctx, args)
    args = args_table(args)
    local before = computer_of(ctx)
    local hostname, err = dir:update_host(ctx.computer_token, {
      hostname = args.hostname,
      id = ctx.sender,
      info = args.info,
      kind = args.kind,
      version = args.version,
    }, now())
    if not hostname then
      return nil, err
    end
    if hostname ~= before then
      save()
    end
    return { hostname = hostname }
  end

  function handlers.resolve(_, args)
    local id = dir:resolve(args_table(args).hostname)
    if not id then
      return nil, "unknown host"
    end
    return { id = id }
  end

  function handlers.list_hosts()
    return dir:list_hosts(now())
  end

  function handlers.service_find(_, args)
    local service = dir:find_service(args_table(args).type)
    if not service then
      return nil, "no such service record"
    end
    return service
  end

  function handlers.service_add(ctx, args)
    args = args_table(args)
    local user, err = require_dns_admin(ctx)
    if not user then
      return nil, err
    end
    return change(dir:add_service(args.type, args.host, args.protocol))
  end

  function handlers.service_del(ctx, args)
    local user, err = require_dns_admin(ctx)
    if not user then
      return nil, err
    end
    return change(dir:remove_service(args_table(args).type))
  end

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
  handlers.list_computers = read_only(function() return dir:list_hosts(now()) end)

  -- Admin-only operations: op name -> function(args) doing the change.
  local admin_operations = {
    user_add = function(args) return dir:add_user(args.name, args.password) end,
    user_del = function(args) return dir:remove_user(args.name) end,
    user_enable = function(args) return dir:set_enabled(args.name, args.is_enabled == true) end,
    group_add = function(args) return dir:add_group(args.name) end,
    group_del = function(args) return dir:remove_group(args.name) end,
    group_addmember = function(args) return dir:add_member(args.group, args.user) end,
    group_rmmember = function(args) return dir:remove_member(args.group, args.user) end,
    computer_remove = function(args) return dir:remove_computer(args.hostname) end,
  }
  for op, operation in pairs(admin_operations) do
    handlers[op] = function(ctx, args)
      local user, err = require_admin(ctx)
      if not user then
        return nil, err
      end
      return change(operation(args_table(args)))
    end
  end

  -- Users may change their own password; admins may change anyone's.
  function handlers.user_passwd(ctx, args)
    args = args_table(args)
    local user, err = require_user(ctx)
    if not user then
      return nil, err
    end
    if user.name ~= args.name and not dir:is_member(directory.ADMINS, user.name) then
      return nil, "permission denied"
    end
    return change(dir:set_password(args.name, args.password))
  end

  return handlers
end

return dc_handlers
