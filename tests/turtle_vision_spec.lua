-- Turtle vision: the turtle side (inspect, Geo Scanner, heading) against stubs, and the
-- driver's map as text.
return function(t)
  -- A stub turtle that only inspects: a stone wall ahead, dirt below.
  local function stub_turtle(front)
    local function block(name)
      return function()
        if name then
          return true, { name = name }
        end
        return false, "No block to inspect"
      end
    end
    return {
      inspect = block(front),
      inspectUp = block(nil),
      inspectDown = block("minecraft:dirt"),
    }
  end

  -- A scanner seeing, in world axes: stone 1 block east, dirt under the turtle and
  -- under the block north of it.
  local function stub_scanner(calls)
    return {
      scan = function(radius)
        calls[#calls + 1] = radius
        return {
          { name = "minecraft:stone", x = 1, y = 0, z = 0, tags = {} },
          { name = "minecraft:dirt", x = 0, y = -1, z = 0, tags = {} },
          { name = "minecraft:dirt", x = 0, y = -1, z = -1, tags = {} },
          { name = "minecraft:chest", x = 0, y = 0, z = 2, tags = {} },
        }
      end,
    }
  end

  local function new_vision(import, front, scanner, gps)
    local turtle_vision = import("turtle_vision")
    local clock = 0
    turtle_vision.env.find_scanner = function() return scanner end
    turtle_vision.env.locate = function() return gps and gps() end
    turtle_vision.env.clock = function() return clock end
    local vision = turtle_vision.new(stub_turtle(front))
    return vision, function(seconds) clock = clock + seconds end
  end

  t.it("without a scanner the turtle still says what is around it", function()
    local import = t.fresh_import()
    local vision = new_vision(import, "minecraft:stone", nil)
    local look = vision.look()
    t.eq(look.near.front, "minecraft:stone")
    t.eq(look.near.up, "minecraft:air")
    t.eq(look.near.down, "minecraft:dirt")
    t.ok(not look.has_scanner)
    t.eq(look.scan, nil)
  end)

  t.it("the heading comes from matching the block ahead against the scan", function()
    local import = t.fresh_import()
    local calls = {}
    local vision, advance = new_vision(import, "minecraft:stone", stub_scanner(calls))
    local look = vision.look()
    t.eq(look.heading, 1, "stone is only to the east: the turtle faces east")
    t.eq(calls[1], 8, "the free radius by default")
    t.ok(#look.scan.cells == 4)
    vision.after_action("turn_left", true)
    t.eq(vision.look().heading, 0, "turning left from east faces north")
    t.eq(#calls, 1, "the scanner is recharging: the kept scan is used")
    advance(3)
    vision.look(40)
    t.eq(calls[2], 16, "radius capped at 16")
  end)

  t.it("moving shifts the kept scan; without a heading or GPS it is dropped", function()
    local import = t.fresh_import()
    local vision = new_vision(import, "minecraft:stone", stub_scanner({}))
    vision.look() -- learns heading east
    vision.after_action("forward", true)
    local look = vision.look()
    t.ok(look.scan.is_shifted)
    local found = false
    for _, cell in ipairs(look.scan.cells) do
      if look.scan.palette[cell[4]] == "minecraft:stone" then
        found = cell[1] == 0 and cell[3] == 0
      end
    end
    t.ok(found, "the stone that was 1 east is now where the turtle is")

    local lost = new_vision(import, nil, stub_scanner({}))
    lost.look() -- air ahead matches several sides: heading unknown
    t.eq(lost.heading, nil)
    lost.after_action("forward", true)
    t.eq(lost.scan, nil, "a scan that cannot be placed any more is dropped")
  end)

  t.it("GPS before and after a move tells the heading", function()
    local import = t.fresh_import()
    local position = { x = 10, y = 64, z = 10 }
    local vision = new_vision(import, nil, nil, function()
      return { x = position.x, y = position.y, z = position.z }
    end)
    t.eq(vision.look().pos.x, 10)
    position.z = 11 -- moved one block south
    vision.after_action("forward", true)
    t.eq(vision.heading, 2)
    vision.after_action("forward", false)
    t.eq(vision.pos.z, 11, "a failed move changes nothing")
  end)

  t.it("without GPS hosts the turtle does not wait for GPS on every look", function()
    local import = t.fresh_import()
    local asked = 0
    local has_hosts = false
    local vision, advance = new_vision(import, nil, nil, function()
      asked = asked + 1
      return has_hosts and { x = 1, y = 2, z = 3 } or nil
    end)
    vision.look()
    vision.look()
    vision.position()
    t.eq(asked, 1, "a failed lookup is not repeated at once")
    has_hosts = true
    advance(import("turtle_vision").GPS_RETRY_SECONDS)
    t.eq(vision.look().pos.x, 1, "asked again after a while")
    vision.look()
    t.eq(asked, 2, "a known position needs no more lookups")
  end)

  t.it("the map turns with the turtle: ahead is up", function()
    local import = t.fresh_import()
    local turtle_view = import("turtle_view")
    local look = {
      heading = 1, -- east
      has_scanner = true,
      near = { front = "minecraft:stone" },
      scan = {
        palette = { "minecraft:stone", "minecraft:dirt", "minecraft:chest", "minecraft:water" },
        cells = {
          { 1, 0, 0, 1 }, -- 1 east: ahead
          { 0, -1, -1, 2 }, -- under the block 1 north: left, floor
          { 0, 0, 2, 3 }, -- 2 south: right
          { -1, 0, 0, 4 }, -- 1 west: behind
        },
      },
    }
    local rows = turtle_view.rows(look, 5, 5)
    t.eq(rows[2].text, "  #  ", "stone ahead")
    t.eq(rows[3].text, " .\24 C", "floor on the left, chest two to the right")
    t.eq(rows[4].text, "  ~  ", "water behind")
    t.eq(rows[2].roles[3], "dim")
    look.heading = nil
    t.eq(turtle_view.rows(look, 5, 5)[3].text:sub(3, 3), "?", "heading unknown")
    t.eq(turtle_view.short_name("minecraft:oak_log"), "oak log")
    t.eq(turtle_view.kind("create:item_vault"), "container")
    t.ok(turtle_view.status_text({ has_scanner = false, near = {} }, 0):find("no Geo Scanner"))
  end)

  t.it("advanced screens get real block colours, basic ones keep the symbols", function()
    local import = t.fresh_import()
    local turtle_view = import("turtle_view")
    t.eq(turtle_view.colour("minecraft:grass_block"), "map_green")
    t.eq(turtle_view.colour("minecraft:oak_planks"), "map_brown")
    t.eq(turtle_view.colour("minecraft:sand"), "map_yellow")
    t.eq(turtle_view.colour("minecraft:deepslate"), "map_grey")
    t.eq(turtle_view.colour("minecraft:stone"), "map_light_grey")
    local look = {
      heading = 0, -- north: ahead is -z
      has_scanner = true,
      near = {},
      scan = {
        palette = { "minecraft:grass_block", "minecraft:iron_ore", "minecraft:water",
          "minecraft:sand" },
        cells = {
          { 0, 0, -1, 1 }, -- grass ahead
          { 1, 0, 0, 2 }, -- iron ore to the right
          { -1, 0, 0, 3 }, -- water to the left
          { 0, -1, 1, 4 }, -- sand under the block behind
        },
      },
    }
    local rows = turtle_view.rows(look, 3, 3, 0, true)
    t.eq(rows[1].backgrounds[2], "map_green", "grass ahead is a green cell")
    t.eq(rows[2].text, "~\24*")
    t.eq(rows[2].backgrounds[1], "map_blue")
    t.eq(rows[2].roles[3], "map_pink", "an iron speck")
    t.eq(rows[2].backgrounds[3], "map_light_grey", "in stone")
    t.eq(rows[3].text:sub(2, 2), ".")
    t.eq(rows[3].roles[2], "map_yellow", "floor dots take the floor's colour")
    local plain = turtle_view.rows(look, 3, 3, 0, false)
    t.eq(plain[1].text, " # ", "basic screens: symbols")
    t.eq(plain[1].backgrounds[2], false)
  end)

  t.it("look is part of the remote protocol and needs a driver", function()
    local import = t.fresh_import()
    import("rpc").set_user_validator(function(token)
      return token == "ok" and { name = "alice", groups = {} } or nil
    end)
    import("turtle_vision").env.find_scanner = function() return nil end
    import("turtle_vision").env.locate = function() return nil end
    local handlers = import("turtle_remote").handlers(stub_turtle("minecraft:stone"), nil,
      function() return true end, function() return true end)
    t.ok(not handlers.look({ sender = 3 }, {}), "no login, no look")
    local look = handlers.look({ sender = 3, token = "ok" }, {})
    t.eq(look.near.front, "minecraft:stone")
  end)
end
