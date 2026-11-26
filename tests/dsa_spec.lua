-- The dsa admin tool, driven with simulated keys against a controller running
-- in the same computer (loopback transport).
return function(t)
  local ME = os.getComputerID()
  local DSA = "packages/domain/files/blockos/bin/dsa.lua"

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
    local session = dir:login("admin", "secret", os.clock())
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
        -- Groups are sorted: computer-joiners is first.
        { { "char", "m" } },
        type_line("dave"),
        { { "wait", 0.5 }, { "char", "q" } }))
    end)
    t.ok(dir:is_member("computer-joiners", "dave"))
  end)
end
