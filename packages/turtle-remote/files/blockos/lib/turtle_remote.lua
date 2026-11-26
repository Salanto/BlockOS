--- Turtle remote control: the actions a remote driver may run, and the
-- request handlers of the turtle-remote service (protocol "blockos.remote").
--
-- Kept apart from the service so tests can call the handlers with a stub
-- turtle. Every request needs a logged-in domain user, checked with the
-- domain controller each time (rpc.require_user): no cached logins.
--
-- Operations:
--   info                        { label, fuel, fuel_limit, selected, slots }
--   act { action, slot? }       run one action -> { ok, detail, info }
-- @module turtle_remote

local rpc = import("rpc")

local turtle_remote = {}

turtle_remote.PROTOCOL = "blockos.remote"
turtle_remote.INVENTORY_SLOTS = 16

--- Argument schemas (see wire.validate).
turtle_remote.ARGS = {
  act = {
    action = { type = "string", max = 16 },
    slot = { type = "number", min = 1, max = 16, optional = true },
  },
}

--- What a driver may do: action name -> turtle function name. Only these run;
-- anything else is refused, so a request can never call arbitrary functions.
turtle_remote.ACTIONS = {
  forward = "forward",
  back = "back",
  up = "up",
  down = "down",
  turn_left = "turnLeft",
  turn_right = "turnRight",
  dig = "dig",
  dig_up = "digUp",
  dig_down = "digDown",
  place = "place",
  place_up = "placeUp",
  place_down = "placeDown",
  suck = "suck",
  drop = "drop",
  refuel = "refuel",
}

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
    if not args.slot then
      return nil, "select needs a slot"
    end
    return turtle_api.select(args.slot), nil
  end
  local function_name = turtle_remote.ACTIONS[args.action]
  if not function_name then
    return nil, "unknown action: " .. args.action
  end
  return turtle_api[function_name]()
end

--- Build the handler table.
-- @tparam table turtle_api The turtle API (tests pass a stub).
-- @tparam[opt] table log A logger (info), to note who drove the turtle.
-- @treturn table { [op] = function(request_ctx, args) }
function turtle_remote.handlers(turtle_api, log)
  local handlers = {}

  function handlers.info(ctx)
    local user, err = rpc.require_user(ctx)
    if not user then
      return nil, err
    end
    return turtle_remote.info(turtle_api)
  end

  -- The last driver is logged once per change of driver, not per keypress.
  local last_driver = nil
  handlers.act = rpc.with_args(turtle_remote.ARGS.act, function(ctx, args)
    local user, err = rpc.require_user(ctx)
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

  return handlers
end

return turtle_remote
