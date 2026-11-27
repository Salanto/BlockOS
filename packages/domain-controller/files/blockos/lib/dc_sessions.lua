--- Joining, leaving and logging in (the domain controller's sessions).
-- Part of the domain controller's handlers (see dc_handlers): attached when they are made.
-- @module dc_sessions


local dc_sessions = {}

--- Add this part's handlers.
-- @tparam table handlers
-- @tparam table internal What dc_handlers shares with its parts.
function dc_sessions.attach(handlers, internal)
  local dir = internal.dir
  local ARGS = internal.args
  local now = internal.now
  local with_args = internal.with_args
  local require_computer = internal.require_computer
  local change = internal.change
  local save_sessions = internal.save_sessions

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
    local session, login_error = dir:login(args.name, args.password, now(), ctx.sender)
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
end

return dc_sessions
