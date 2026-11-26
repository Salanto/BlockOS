-- Accounts, first-boot setup, login and logout, driven with simulated key input.
return function(t)
  local function type_line(text)
    return { { "paste", text }, { "key", keys.enter } }
  end

  local function concat(...)
    local all = {}
    for _, list in ipairs({ ... }) do
      for _, item in ipairs(list) do
        all[#all + 1] = item
      end
    end
    return all
  end

  t.it("accounts: add, check, change password, keep the last admin", function()
    local auth = t.fresh_import()("auth")
    t.ok(not auth.has_users())
    t.ok(auth.add_user("alice", "secret", true))
    t.ok(not auth.add_user("alice", "again", false), "duplicate user")
    t.ok(not auth.add_user("bad name!", "x", false), "invalid name")
    t.ok(auth.check("alice", "secret"))
    t.eq(auth.check("alice", "wrong"), nil)
    t.ok(auth.set_password("alice", "new"))
    t.ok(auth.check("alice", "new"))
    t.ok(not auth.remove_user("alice"), "removed the last admin")
  end)

  t.it("a corrupt passwd file counts as no users", function()
    local import = t.fresh_import()
    local auth, paths = import("auth"), import("paths")
    t.write(paths.passwd(), "garbage {{{")
    t.ok(not auth.has_users())
  end)

  t.it("login runs first-boot setup when there are no accounts", function()
    local import = t.fresh_import()
    local auth, session = import("auth"), import("session")
    local accept_default = { { "key", keys.enter } } -- setup pre-fills "admin"
    local input = concat(
      accept_default, type_line("pw"), type_line("pw"), -- setup
      type_line("admin"), type_line("pw"))              -- login
    local user = t.with_input(function() return session.login() end, input)
    t.eq(user.name, "admin")
    t.ok(user.is_admin)
    t.ok(auth.check("admin", "pw"))
  end)

  t.it("login rejects wrong passwords and ignores Ctrl+T", function()
    local import = t.fresh_import()
    import("auth").add_user("bob", "right", false)
    local session = import("session")
    local input = concat(
      type_line("bob"), type_line("wrong"),
      { { "terminate" } },
      type_line("bob"), type_line("right"))
    local user = t.with_input(function() return session.login() end, input)
    t.eq(user.name, "bob")
  end)

  t.it("logout ends the whole session and restores the terminal", function()
    local import = t.fresh_import()
    local session = import("session")
    local before = term.current()
    local finished = false
    local fake_shell = function()
      -- Stand-in for a shell with tabs: it redirects the terminal and never exits.
      term.redirect(window.create(term.current(), 1, 1, 10, 5))
      while true do
        os.pullEvent()
      end
    end
    t.with_input(function()
      session.run_user({ name = "carol" }, fake_shell)
      finished = true
    end, { { session.LOGOUT_EVENT } })
    t.ok(finished)
    t.eq(term.current(), before)
  end)

  t.it("advanced devices get a nested multishell, basic ones a plain shell", function()
    local import = t.fresh_import()
    local session = import("session")
    local ran = nil
    local fake_shell_api = { run = function(program) ran = program end }
    session.default_shell(fake_shell_api)()
    if term.isColour() then
      t.eq(ran, "/rom/programs/advanced/multishell.lua")
    else
      t.eq(ran, "/rom/programs/shell.lua")
    end
  end)
end
