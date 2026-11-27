--- The turtle remote protocol (protocol "blockos.remote"), shared by the turtle side
-- (turtle-remote) and the driver (turtle-driver): what a driver may ask for.
--
-- Operations:
--   info                        { label, fuel, fuel_limit, selected, slots }
--   act { action, slot? }       run one action -> { ok, detail, info }
--   look { radius? }            what the turtle sees (read-only): { near = { front, up,
--                               down }, heading? (0 north .. 3 west), pos?, has_scanner,
--                               scan_error?, scan? = { radius, age, is_shifted, palette,
--                               cells = { { x, y, z, palette index } } } }; offsets from
--                               the turtle in world axes, the layers around its height
--   follow { player, distance? } walk after a player (never digs) -> { following }
--   stop                        stop following -> { stopped }
-- info also says { following?, follow_status? }.
-- @module turtle_remote_wire

local turtle_remote_wire = {}

turtle_remote_wire.PROTOCOL = "blockos.remote"
turtle_remote_wire.ROLE = "turtle-drivers"
turtle_remote_wire.INVENTORY_SLOTS = 16

--- Argument schemas (see wire.validate).
turtle_remote_wire.ARGS = {
  act = {
    action = { type = "string", max = 16 },
    -- wire's `max` limits lengths, not numbers: the turtle checks the upper bound.
    slot = { type = "number", min = 1, optional = true },
  },
  look = {
    radius = { type = "number", min = 1, optional = true },
  },
  follow = {
    player = { type = "string", max = 32 },
    distance = { type = "number", min = 1, optional = true },
  },
}

--- What a driver may do: action name -> turtle function name. Only these run;
-- anything else is refused, so a request can never call arbitrary functions.
turtle_remote_wire.ACTIONS = {
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

return turtle_remote_wire
