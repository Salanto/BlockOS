-- Device detection and the UI on basic, advanced and turtle-sized screens.
return function(t)
  -- Stand-in turtle API: CraftOS-PC does not emulate turtles.
  local function fake_turtle(fuel)
    return {
      getFuelLevel = function() return fuel end,
      getFuelLimit = function() return 20000 end,
      getItemCount = function(slot) return slot <= 3 and 1 or 0 end,
    }
  end

  local function with_global(name, value, fn)
    local previous = _G[name]
    _G[name] = value
    local ok, err = pcall(fn)
    _G[name] = previous
    if not ok then
      error(err, 0)
    end
  end

  local function with_screen(width, height, fn)
    local original = term.current()
    term.redirect(window.create(term.native(), 1, 1, width, height))
    local ok, err = pcall(fn)
    term.redirect(original)
    if not ok then
      error(err, 0)
    end
  end

  t.it("detects advanced or basic from the terminal", function()
    local device = t.fresh_import()("device")
    t.eq(device.is_advanced(), term.isColour())
    t.eq(device.kind(), "computer")
  end)

  t.it("detects a turtle", function()
    with_global("turtle", fake_turtle(100), function()
      local device = t.fresh_import()("device")
      t.eq(device.kind(), "turtle")
    end)
  end)

  t.it("basic devices get a greyscale theme", function()
    local ui = t.fresh_import()("ui")
    local greys = {
      [colours.white] = true, [colours.black] = true,
      [colours.grey] = true, [colours.lightGrey] = true,
    }
    if term.isColour() then
      t.skip("only meaningful on a basic computer")
    end
    for role, colour in pairs(ui.theme()) do
      t.ok(greys[colour], "role " .. role .. " is not greyscale")
    end
  end)

  t.it("wrap respects the width", function()
    local ui = t.fresh_import()("ui")
    for _, line in ipairs(ui.wrap("a fairly long sentence that must wrap nicely", 10)) do
      t.ok(#line <= 10, "line too long: " .. line)
    end
  end)

  t.it("menus work with the keyboard only, on a turtle-sized screen", function()
    local ui = t.fresh_import()("ui")
    with_screen(39, 13, function()
      local choice = t.with_input(function()
        return ui.menu({ title = "Test", text = "Pick one", items = { "one", "two", "three" } })
      end, { { "key", keys.down }, { "key", keys.down }, { "key", keys.enter } })
      t.eq(choice, 3)
    end)
  end)

  t.it("menus pick the default when the timeout runs out", function()
    local ui = t.fresh_import()("ui")
    local choice = ui.menu({ title = "Test", items = { "a", "b" }, default = 2, timeout = 1 })
    t.eq(choice, 2)
  end)

  t.it("turtle-info reports fuel, including unlimited fuel", function()
    with_global("turtle", fake_turtle("unlimited"), function()
      t.fresh_import()
      local path = fs.combine(t.repo, "packages/net/files/blockos/services/turtle-info.lua")
      local definition = assert(loadfile(path, nil, _ENV))()
      local status = definition.collect_status()
      t.eq(status.fuel, "unlimited")
      t.eq(status.free_slots, 13)
    end)
  end)
end
