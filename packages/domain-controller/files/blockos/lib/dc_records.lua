--- Host and service records: who is where, what runs where.
-- Part of the domain controller's handlers (see dc_handlers): attached when they are made.
-- @module dc_records


local dc_records = {}

--- Add this part's handlers.
-- @tparam table handlers
-- @tparam table internal What dc_handlers shares with its parts.
function dc_records.attach(handlers, internal)
  local dir = internal.dir
  local storage = internal.storage
  local ARGS = internal.args
  local now = internal.now
  local today = internal.today
  local with_args = internal.with_args
  local require_computer = internal.require_computer
  local require_admin = internal.require_admin
  local change = internal.change

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
end

return dc_records
