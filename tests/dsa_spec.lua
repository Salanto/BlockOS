-- The dsa admin tool, driven with simulated keys against a controller running
-- in the same computer (loopback transport).
return function(t)
  local ME = os.getComputerID()
  local DSA = "packages/domain-tools/files/blockos/bin/dsa.lua"

  local function type_line(text)
    return { { "paste", text }, { "key", keys.enter } }
  end

  local function steps(...)
    local all = {}
    for _, list in ipairs({ ... }) do
      for _, step in ipairs(list) do
        all[#all + 1] = step
      end
    end
    return all
  end

  -- A domain "home" served locally; this computer is joined and logged in as admin.
  local function setup()
    local import = t.fresh_import()
    local rpc = import("rpc")
    local dir = assert(import("directory").create("home", "admin", "secret"))
    local token = dir:join("pc1", ME)
    import("domain").set_membership({ name = "home", controller_id = ME, computer_token = token })
    -- Sessions are measured in real seconds, like the controller does.
    local session = dir:login("admin", "secret", math.floor(os.epoch("utc") / 1000))
    _G.blockos = { ui = import("ui"), user = { name = "admin", token = session.token } }
    rpc.set_transport(rpc.loopback_transport())
    local storage = { save = function() return true end, has_room = function() return true end }
    local handlers = import("dc_handlers").new(dir, storage)
    return dir, rpc, handlers
  end

  local function run_dsa(rpc, handlers, input)
    parallel.waitForAny(
      function() rpc.serve("blockos.domain", handlers) end,
      function()
        t.with_input(function() shell.run(fs.combine(t.repo, DSA)) end, input)
      end
    )
  end

  local function with_screen(width, height, fn)
    local original = term.current()
    term.redirect(window.create(term.current(), 1, 1, width, height))
    local ok, err = pcall(fn)
    term.redirect(original)
    if not ok then
      error(err, 0)
    end
  end

  t.it("adds a user from the Users tab", function()
    local dir, rpc, handlers = setup()
    run_dsa(rpc, handlers, steps(
      { { "wait", 0.5 }, { "char", "a" } },
      type_line("carol"), type_line("pw"),
      { { "wait", 0.5 }, { "char", "q" } }))
    t.ok(dir.data.users.carol, "carol was not created")
  end)

  t.it("adds a group member from the Groups tab on a turtle-sized screen", function()
    local dir, rpc, handlers = setup()
    dir:add_user("dave", "pw")
    with_screen(39, 13, function()
      run_dsa(rpc, handlers, steps(
        { { "wait", 0.5 }, { "char", "2" }, { "wait", 0.5 } },
        -- Groups are sorted: domain-admins is first.
        { { "char", "m" } },
        type_line("dave"),
        { { "wait", 0.5 }, { "char", "q" } }))
    end)
    t.ok(dir:is_member("domain-admins", "dave"))
  end)

  -- What the package source offers in the role tests.
  local PACKAGES = {
    music = { optional = true, kind = "application", description = "Plays music" },
    logistics = { optional = true, kind = "bundle", description = "Storage for players" },
    ["logistics-protocol"] = { optional = true, kind = "protocol" },
    ["domain-controller"] = { optional = true, exclusive = true, kind = "application" },
    net = { kind = "base" },
  }

  t.it("the role picker offers packages worth choosing and assigns only changes", function()
    t.fresh_import()
    local role_picker = import("role_picker")
    local items = role_picker.package_items(PACKAGES, { "music", "gone" })
    local names = {}
    for _, item in ipairs(items) do
      names[#names + 1] = item.name
    end
    t.eq(table.concat(names, ","), "logistics,music,gone",
      "no protocols, base or exclusive packages; a vanished one stays listed")
    t.eq(items[2].detail, "Plays music")
    t.ok(items[2].is_checked and items[3].is_checked and not items[1].is_checked)
    t.eq(table.concat(role_picker.ticked(items, { [1] = true }), ","), "logistics")

    local hosts = {
      { hostname = "farm", kind = "computer", roles = { "display" } },
      { hostname = "mine", kind = "turtle", roles = { "miner" } },
      { hostname = "shop", kind = "computer" },
    }
    local computer_items = role_picker.computer_items("display", hosts)
    t.ok(computer_items[1].is_checked and not computer_items[2].is_checked)
    t.ok(computer_items[2].detail:find("turtle"), computer_items[2].detail)
    local changes = role_picker.computer_changes("display", computer_items,
      { [2] = true, [3] = true })
    t.eq(#changes, 3, "farm loses it, mine and shop get it")
    t.eq(#changes[1].roles, 0)
    t.eq(table.concat(changes[2].roles, ","), "miner,display", "other roles are kept")
    t.eq(#role_picker.computer_changes("display", computer_items, { [1] = true }), 0,
      "nothing changed: nothing to assign")
  end)

  t.it("a checklist ticks with Space, saves with Enter and cancels with q", function()
    local ui = t.fresh_import()("ui")
    local items = { { label = "a" }, { label = "b", is_checked = true }, { label = "c" } }
    local result = t.with_input(function() return ui.checklist({ title = "T", items = items }) end,
      { { "char", " " }, { "key", keys.down }, { "char", " " }, { "key", keys.down },
        { "key", keys.enter } })
    t.ok(result[1] and not result[2] and not result[3], "a ticked, b unticked")
    t.eq(t.with_input(function() return ui.checklist({ title = "T", items = items }) end,
      { { "char", " " }, { "char", "q" } }), nil, "q cancels")
  end)

  t.it("adds a computer role by ticking packages and computers", function()
    local dir, rpc, handlers = setup()
    import("role_picker").env.index = function() return { packages = PACKAGES } end
    run_dsa(rpc, handlers, steps(
      { { "wait", 0.5 }, { "char", "4" }, { "wait", 0.5 }, { "char", "a" } },
      type_line("farm-display"),
      -- Packages: logistics, music. Tick both.
      { { "wait", 0.3 }, { "char", " " }, { "key", keys.down }, { "char", " " },
        { "key", keys.enter } },
      -- Computers: pc1 only. Tick it.
      { { "wait", 0.5 }, { "char", " " }, { "key", keys.enter } },
      { { "wait", 0.5 }, { "char", "q" } }))
    local role = dir.data.computer_roles["farm-display"]
    t.ok(role, "the role was not created")
    t.eq(table.concat(role.packages, ","), "logistics,music")
    t.eq(table.concat(dir.data.computers.pc1.roles or {}, ","), "farm-display")
  end)
end
