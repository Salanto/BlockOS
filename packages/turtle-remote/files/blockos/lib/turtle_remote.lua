--- Turtle remote control: the actions a remote driver may run, and the
-- request handlers of the turtle-remote service (protocol "blockos.remote").
--
-- Kept apart from the service so tests can call the handlers with a stub
-- turtle. Without a domain anyone may drive (standalone first, friends only). In a
-- domain every request needs a logged-in domain user, checked with the domain
-- controller each time (rpc.require_user): no cached logins. Once a domain admin ran
-- `domain setup turtle-remote`, the user also needs the turtle-drivers role.
--
-- Operations:
--   info                        { label, fuel, fuel_limit, selected, slots }
--   act { action, slot? }       run one action -> { ok, detail, info }
-- @module turtle_remote

local rpc = import("rpc")

local turtle_remote = {}

-- The protocol is declared once in turtle_remote_wire (shared with the driver).
local turtle_remote_wire = import("turtle_remote_wire")
turtle_remote.PROTOCOL = turtle_remote_wire.PROTOCOL
turtle_remote.ROLE = turtle_remote_wire.ROLE
turtle_remote.INVENTORY_SLOTS = turtle_remote_wire.INVENTORY_SLOTS
turtle_remote.ARGS = turtle_remote_wire.ARGS
turtle_remote.ACTIONS = turtle_remote_wire.ACTIONS

--- The turtle's state, for the driver's screen. Read-only calls only.
-- @tparam table turtle_api The turtle API (tests pass a stub).
-- @treturn table { label, fuel, fuel_limit, selected, slots = { [n] = count } }
function turtle_remote.info(turtle_api)
  local slots = {}
  for slot = 1, turtle_remote.INVENTORY_SLOTS do
    slots[slot] = turtle_api.getItemCount(slot)
  end
  return {
    label = os.getComputerLabel(),
    fuel = turtle_api.getFuelLevel(),
    fuel_limit = turtle_api.getFuelLimit(),
    selected = turtle_api.getSelectedSlot(),
    slots = slots,
  }
end

-- Run one action. Turtle functions return true, or false and a reason.
local function run_action(turtle_api, args)
  if args.action == "select" then
    local slot = args.slot
    if not slot or slot > turtle_remote.INVENTORY_SLOTS or slot % 1 ~= 0 then
      return nil, "select needs a slot from 1 to " .. turtle_remote.INVENTORY_SLOTS
    end
    return turtle_api.select(args.slot), nil
  end
  local function_name = turtle_remote.ACTIONS[args.action]
  if not function_name then
    return nil, "unknown action: " .. args.action
  end
  return turtle_api[function_name]()
end

-- Logged in, and (in managed mode) holding the turtle-drivers role.
local function default_allows(ctx)
  return import("roles").allows(ctx, turtle_remote.ROLE)
end

--- Build the handler table.
-- @tparam table turtle_api The turtle API (tests pass a stub).
-- @tparam[opt] table log A logger (info), to note who drove the turtle.
-- @tparam[opt] function allows function(ctx) -> true or nil, err; default: roles.allows
--   with turtle-drivers (tests pass their own)
-- @tparam[opt] function is_joined function() -> boolean (default: ask the domain)
-- @treturn table { [op] = function(request_ctx, args) }
function turtle_remote.handlers(turtle_api, log, allows, is_joined)
  local handlers = {}
  allows = allows or default_allows
  is_joined = is_joined or function()
    local found, domain = pcall(import, "domain")
    return found and domain.is_joined()
  end

  local function require_driver(ctx)
    if not is_joined() then
      return { name = "#" .. tostring(ctx.sender) } -- standalone: open
    end
    local user, err = rpc.require_user(ctx)
    if not user then
      return nil, err
    end
    local ok, role_err = allows(ctx)
    if not ok then
      return nil, role_err
    end
    return user
  end

  function handlers.info(ctx)
    local user, err = require_driver(ctx)
    if not user then
      return nil, err
    end
    return turtle_remote.info(turtle_api)
  end

  -- The last driver is logged once per change of driver, not per keypress.
  local last_driver = nil
  handlers.act = rpc.with_args(turtle_remote.ARGS.act, function(ctx, args)
    local user, err = require_driver(ctx)
    if not user then
      return nil, err
    end
    if log and user.name ~= last_driver then
      log.info("driven by %s from #%s", tostring(user.name), tostring(ctx.sender))
      last_driver = user.name
    end
    local ok, detail = run_action(turtle_api, args)
    if ok == nil and detail then
      return nil, detail
    end
    return { ok = ok == true, detail = detail, info = turtle_remote.info(turtle_api) }
  end)
  rpc.once(handlers.act) -- a repeat must never move the turtle twice

  return handlers
end

return turtle_remote
