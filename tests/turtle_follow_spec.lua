-- Following a player, with a stub turtle that really moves in a small fake world, and the
-- player locator's handlers with a stub detector.
return function(t)
  -- A turtle at x, y, z facing `heading` (0 north .. 3 west); `walls` are blocked blocks.
  local function world_turtle(walls)
    local DIRECTIONS = { [0] = { 0, -1 }, [1] = { 1, 0 }, [2] = { 0, 1 }, [3] = { -1, 0 } }
    local bot = { x = 0, y = 64, z = 0, heading = 1, fuel = 500, moves = {} }
    local function blocked(x, y, z)
      return walls[x .. "," .. y .. "," .. z]
    end
    local function step(dx, dy, dz, name)
      if blocked(bot.x + dx, bot.y + dy, bot.z + dz) then
        return false, "Movement obstructed"
      end
      bot.x, bot.y, bot.z = bot.x + dx, bot.y + dy, bot.z + dz
      bot.fuel = bot.fuel - 1
      bot.moves[#bot.moves + 1] = name
      return true
    end
    bot.api = {
      forward = function()
        local d = DIRECTIONS[bot.heading]
        return step(d[1], 0, d[2], "forward")
      end,
      up = function() return step(0, 1, 0, "up") end,
      down = function() return step(0, -1, 0, "down") end,
      turnLeft = function() bot.heading = (bot.heading + 3) % 4 return true end,
      turnRight = function() bot.heading = (bot.heading + 1) % 4 return true end,
      getFuelLevel = function() return bot.fuel end,
      dig = function() error("following must never dig") end,
    }
    return bot
  end

  local function setup(walls, player)
    local import = t.fresh_import()
    local bot = world_turtle(walls or {})
    local turtle_vision = import("turtle_vision")
    turtle_vision.env.find_scanner = function() return nil end
    turtle_vision.env.locate = function() return { x = bot.x, y = bot.y, z = bot.z } end
    local turtle_follow = import("turtle_follow")
    local clock = 0
    turtle_follow.env.where = function()
      if not player.x then
        return nil, "alice not found"
      end
      return { name = "alice", x = player.x + 0.5, y = player.y, z = player.z + 0.5 }
    end
    turtle_follow.env.clock = function() return clock end
    local vision = turtle_vision.new(bot.api)
    local follower = turtle_follow.new(bot.api, vision)
    return follower, bot, vision, function(seconds) clock = clock + seconds end
  end

  local function run_steps(follower, count)
    for _ = 1, count do
      follower.step()
    end
  end

  t.it("walks toward the player and stops a few blocks away", function()
    local player = { x = 10, y = 64, z = 0 }
    local follower, bot = setup({}, player)
    follower.start("alice")
    run_steps(follower, 20)
    t.eq(bot.x, 7, "3 blocks short of the player")
    t.ok(follower.status:find("next to"), tostring(follower.status))
    player.z = 6
    run_steps(follower, 20)
    t.ok(math.abs(bot.x - 10) + math.abs(bot.z - 6) <= 3, bot.x .. "," .. bot.z)
  end)

  t.it("goes around a wall, or over it, and never digs", function()
    local walls = { ["1,64,0"] = true, ["2,64,0"] = true }
    local follower, bot = setup(walls, { x = 8, y = 64, z = 0 })
    follower.start("alice", 1)
    run_steps(follower, 40)
    t.ok(math.abs(bot.x - 8) + math.abs(bot.z) <= 1, "arrived: " .. bot.x .. "," .. bot.z)
  end)

  t.it("gives up when stuck, lost, too far or low on fuel", function()
    local box = {}
    for _, offset in ipairs({ "1,64,0", "-1,64,0", "0,64,1", "0,64,-1", "0,65,0", "0,63,0" }) do
      box[offset] = true
    end
    local stuck = setup(box, { x = 9, y = 64, z = 0 })
    stuck.start("alice")
    run_steps(stuck, 30)
    t.eq(stuck.target, nil)
    t.eq(stuck.status, "stuck")

    local player = {}
    local lost, _, _, advance = setup({}, player)
    lost.start("alice")
    lost.step()
    t.eq(lost.target, "alice", "a short gap is fine")
    advance(31)
    lost.step()
    t.eq(lost.status, "lost alice")

    local far = setup({}, { x = 500, y = 64, z = 0 })
    far.start("alice")
    far.step()
    t.ok(far.status:find("too far"))

    local hungry, bot = setup({}, { x = 9, y = 64, z = 0 })
    bot.fuel = 5
    hungry.start("alice")
    hungry.step()
    t.eq(hungry.status, "low on fuel")
  end)

  t.it("a manual action takes over from following", function()
    local import = t.fresh_import()
    import("rpc").set_user_validator(function() return { name = "bob", groups = {} } end)
    import("turtle_vision").env.find_scanner = function() return nil end
    local bot = world_turtle({})
    bot.api.getItemCount = function() return 0 end
    bot.api.getFuelLimit = function() return 20000 end
    bot.api.getSelectedSlot = function() return 1 end
    bot.api.back = function() return true end
    local handlers, follower = import("turtle_remote").handlers(bot.api, nil,
      function() return true end, function() return true end)
    local ctx = { sender = 3, token = "t" }
    t.eq(handlers.follow(ctx, { player = "alice" }).following, "alice")
    t.eq(handlers.info(ctx).following, "alice")
    handlers.act(ctx, { action = "back" })
    t.eq(follower.target, nil)
    t.ok(follower.status:find("taken over by bob"))
  end)

  t.it("the player locator answers from a Player Detector", function()
    local import = t.fresh_import()
    local detector = {
      getPlayerPos = function(name)
        if name == "alice" then
          return { x = 1.5, y = 64, z = -3.5, dimension = "minecraft:overworld" }
        end
        return nil
      end,
      getOnlinePlayers = function() return { "alice", "bob" } end,
    }
    local handlers = import("player_locator").handlers(function() return detector end)
    t.eq(handlers.where({}, { name = "alice" }).z, -3.5)
    local missing, err = handlers.where({}, { name = "carol" })
    t.ok(not missing and err:find("not found"))
    t.eq(#handlers.online({}), 2)
    local none = import("player_locator").handlers(function() return nil end)
    t.ok(not none.online({}))
  end)
end
