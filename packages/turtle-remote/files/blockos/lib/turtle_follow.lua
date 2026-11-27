--- Follow a player: walk toward them and stay a few blocks away (ops follow and stop of
-- protocol blockos.remote). Started and stopped only by a driver's request; any manual
-- action stops it, so the driver always has the last word.
--
-- Never digs: it walks around or climbs over what is in the way, and gives up when stuck.
-- Needs GPS (where the turtle is) and a player locator (where the player is, see
-- players.lua). Stops by itself on low fuel, when the player is out of sight for a while,
-- or when they are too far away.
-- @module turtle_follow

local turtle_follow = {}

--- Blocks to stay away from the player (horizontally) unless asked otherwise.
turtle_follow.DEFAULT_DISTANCE = 3
--- Give up when the player is further than this (it would get lost on the way).
turtle_follow.MAX_DISTANCE = 128
--- Give up after this long without knowing where the player is.
turtle_follow.LOST_SECONDS = 30
--- Give up after this many steps in a row that went nowhere.
turtle_follow.MAX_BLOCKED = 12
--- Stop below this much fuel (so it can still be driven home).
turtle_follow.MIN_FUEL = 20
turtle_follow.STEP_SECONDS = 0.3
turtle_follow.IDLE_SECONDS = 1

--- Access to the world (tests replace these).
turtle_follow.env = {
  where = function(name)
    return import("players").where(name)
  end,
  clock = os.clock,
  sleep = sleep,
}

local ACTION_FUNCTIONS = {
  forward = "forward", up = "up", down = "down",
  turn_left = "turnLeft", turn_right = "turnRight",
}

--- Make a follower for a turtle.
-- @tparam table turtle_api
-- @tparam table vision Its turtle_vision (heading and position tracking).
-- @tparam[opt] table log
-- @treturn table follower
function turtle_follow.new(turtle_api, vision, log)
  local env = turtle_follow.env
  local follower = {
    target = nil, -- player name
    distance = turtle_follow.DEFAULT_DISTANCE,
    status = nil, -- why it stopped, or what it is doing
    lost_since = nil,
    blocked = 0,
  }

  local function stop(reason)
    if follower.target and log then
      log.info("stopped following %s: %s", follower.target, reason)
    end
    follower.target, follower.status = nil, reason
  end

  -- One move through the turtle, followed by the vision.
  local function try(action)
    local ok = turtle_api[ACTION_FUNCTIONS[action]]()
    vision.after_action(action, ok == true)
    return ok == true
  end

  local function face(heading)
    local turn = (heading - vision.heading) % 4
    if turn == 1 then
      try("turn_right")
    elseif turn == 2 then
      try("turn_right")
      try("turn_right")
    elseif turn == 3 then
      try("turn_left")
    end
  end

  local function low_on_fuel()
    local fuel = turtle_api.getFuelLevel()
    return type(fuel) == "number" and fuel < turtle_follow.MIN_FUEL
  end

  -- Headings toward the player, the longer way first: 0 north (-z) .. 3 west (-x).
  local function headings_toward(dx, dz)
    local options = {}
    if dx ~= 0 then
      options[#options + 1] = { heading = dx > 0 and 1 or 3, amount = math.abs(dx) }
    end
    if dz ~= 0 then
      options[#options + 1] = { heading = dz > 0 and 2 or 0, amount = math.abs(dz) }
    end
    table.sort(options, function(a, b) return a.amount > b.amount end)
    return options
  end

  -- Try to get one block closer; true when the turtle moved.
  local function move_toward(dx, dy, dz)
    if dy > 1 and try("up") then
      return true
    elseif dy < -1 and try("down") then
      return true
    end
    if vision.heading == nil then
      -- The first step tells the heading (GPS before and after); turn if blocked.
      return try("forward") or (try("turn_right") and false)
    end
    for _, option in ipairs(headings_toward(dx, dz)) do
      face(option.heading)
      if try("forward") then
        return true
      end
    end
    return try("up") -- blocked both ways: climb over
  end

  --- One step of following (called over and over while following).
  -- @treturn boolean true when it moved (so the next step comes sooner)
  function follower.step()
    if not follower.target then
      return false
    end
    if low_on_fuel() then
      stop("low on fuel")
      return false
    end
    local player, err = env.where(follower.target)
    if not player then
      follower.lost_since = follower.lost_since or env.clock()
      follower.status = tostring(err)
      if env.clock() - follower.lost_since > turtle_follow.LOST_SECONDS then
        stop("lost " .. follower.target)
      end
      return false
    end
    follower.lost_since = nil
    local here = vision.position()
    if not here then
      stop("needs GPS to follow")
      return false
    end
    local dx = math.floor(player.x) - here.x
    local dy = math.floor(player.y) - here.y
    local dz = math.floor(player.z) - here.z
    local horizontal = math.abs(dx) + math.abs(dz)
    if horizontal + math.abs(dy) > turtle_follow.MAX_DISTANCE then
      stop(follower.target .. " is too far away")
      return false
    end
    if horizontal <= follower.distance and math.abs(dy) <= 1 then
      follower.status, follower.blocked = "next to " .. follower.target, 0
      return false
    end
    if move_toward(dx, dy, dz) then
      follower.status, follower.blocked = "following " .. follower.target, 0
      return true
    end
    follower.blocked = follower.blocked + 1
    if follower.blocked >= turtle_follow.MAX_BLOCKED then
      stop("stuck")
    end
    return false
  end

  --- Start following a player.
  -- @tparam string name
  -- @tparam[opt] number distance
  function follower.start(name, distance)
    follower.target = name
    follower.distance = math.max(1, math.floor(distance or turtle_follow.DEFAULT_DISTANCE))
    follower.status, follower.lost_since, follower.blocked = "following " .. name, nil, 0
    if log then
      log.info("following %s", name)
    end
  end

  --- Stop following.
  -- @tparam[opt] string reason
  function follower.stop(reason)
    stop(reason or "stopped")
  end

  --- Run forever: steps while following, idles otherwise (the service runs this).
  function follower.run()
    while true do
      local ok, result = pcall(follower.step)
      if not ok then
        stop("error: " .. tostring(result))
      end
      local moved = ok and result
      env.sleep(moved and turtle_follow.STEP_SECONDS or turtle_follow.IDLE_SECONDS)
    end
  end

  return follower
end

return turtle_follow
