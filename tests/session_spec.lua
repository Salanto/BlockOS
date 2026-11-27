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

  -- A stand-in for the domain package's login provider.
  local function fake_domain_provider(is_available)
    return {
      describe = function() return "Domain: home" end,
      is_available = function() return is_available end,
      name = function() return "home" end,
      login = function(name, password)
        if password ~= "domain-pw" then
          return nil, "Login incorrect."
        end
        return { name = name, source = "domain", groups = { "domain-admins" }, is_admin = true }
      end,
    }
  end

  t.it("bare names use the domain once joined; local names start with .\\", function()
    local auth = t.fresh_import()("auth")
    auth.add_user("admin", "local-pw", true)
    auth.register_provider("domain", fake_domain_provider(true))
    t.eq(auth.login("alice", "domain-pw").source, "domain")
    t.eq(auth.login("home\\alice", "domain-pw").source, "domain")
    t.eq(auth.login(".\\admin", "local-pw").source, "local")
    t.ok(not auth.login("other\\alice", "domain-pw"), "unknown domains are refused")
    t.ok(auth.login_hint():find("Domain: home"))
  end)

  t.it("local accounts work while the domain is unavailable", function()
    local auth = t.fresh_import()("auth")
    auth.add_user("admin", "local-pw", true)
    auth.register_provider("domain", fake_domain_provider(false))
    local user = auth.login("admin", "local-pw")
    t.eq(user.source, "local")
    t.ok(user.is_admin)
    t.eq(auth.login_hint(), nil)
  end)

  t.it("domain admins are administrators on the computer", function()
    local import = t.fresh_import()
    local domain = import("domain")
    t.ok(domain.is_admin({ groups = { "domain-users", "domain-admins" } }))
    t.ok(not domain.is_admin({ groups = { "domain-users" } }))
  end)

  t.it("autologin picks an existing local user, and nobody otherwise", function()
    local import = t.fresh_import()
    import("auth").add_user("farm", "pw", false)
    local session = import("session")
    local previous = settings.get("blockos.autologin")
    settings.set("blockos.autologin", "farm")
    local user = session.autologin_user()
    settings.set("blockos.autologin", "ghost")
    local missing = session.autologin_user()
    if previous == nil then
      settings.unset("blockos.autologin")
    else
      settings.set("blockos.autologin", previous)
    end
    t.eq(user.name, "farm")
    t.eq(user.source, "local")
    t.eq(missing, nil, "an unknown user is never logged in")
  end)

  t.it("login hooks add apps and roaming settings; a failing hook is skipped", function()
    local import = t.fresh_import()
    local session = import("session")
    local config = import("config")
    session.set_login_hook("a", function(user)
      return { apps = { "logistics" }, settings = { ["blockos.test.roams"] = user.name } }
    end)
    session.set_login_hook("b", function() error("controller down") end)
    session.set_login_hook("c", function() return { apps = { "music" } } end)
    local profile = session.profile_for({ name = "bob" })
    t.eq(table.concat(profile.apps, ","), "logistics,music")
    t.eq(profile.settings["blockos.test.roams"], "bob")
    session.set_login_hook("c", nil)
    t.eq(#session.profile_for({ name = "bob" }).apps, 1, "a hook can be removed")

    config.define("blockos.test.roams", { description = "test", type = "string", roams = true })
    config.define("blockos.test.local", { description = "test", type = "string" })
    t.ok(config.roams("blockos.test.roams"))
    t.ok(not config.roams("blockos.test.local"))
    config.set_session({ ["blockos.test.roams"] = "bob", ["blockos.test.local"] = "x" })
    t.eq(config.get("blockos.test.roams"), "bob", "a roaming value applies for the session")
    t.eq(config.get_system("blockos.test.roams"), nil, "services never see it")
    t.eq(config.get("blockos.test.local"), nil, "other keys never come from a profile")
    config.set_session(nil)
    t.eq(config.get("blockos.test.roams"), nil, "gone after logout")
    settings.undefine("blockos.test.roams")
    settings.undefine("blockos.test.local")
  end)

  t.it("the rom's multishell can start the session's apps in its first tab", function()
    local session = t.fresh_import()("session")
    local file = fs.open("/rom/programs/advanced/multishell.lua", "r")
    local source = file.readAll()
    file.close()
    local patched = session.patch_multishell(source)
    local start = source:find("launchProcess%(%s*true")
    t.ok(patched, "the rom's multishell starts its first shell as expected: "
      .. tostring(start and source:sub(start, start + 120)))
    t.ok(patched and patched:find('shell.lua", ...)', 1, true))
    t.ok(load(patched, "=multishell"), "still valid Lua")
    t.eq(session.patch_multishell("print('something else')"), nil)
    -- CC:Tweaked 1.115's own multishell (CraftOS-PC's rom differs).
    local tweaked = table.concat({
      "launchProcess(true, {",
      '    ["shell"] = shell,',
      '}, "/rom/programs/shell.lua")',
    }, "\n")
    local changed = session.patch_multishell(tweaked)
    t.ok(changed and changed:find('shell.lua", ...)', 1, true), tostring(changed))
  end)

  t.it("the mail sound comes from a setting and plays on a speaker", function()
    local import = t.fresh_import()
    local domain = import("domain")
    t.eq(domain.mail_sound("note:chime").kind, "note")
    t.eq(domain.mail_sound("file:/sounds/mail.dfpwm").value, "/sounds/mail.dfpwm")
    t.eq(domain.mail_sound("sound:minecraft:entity.villager.yes").value,
      "minecraft:entity.villager.yes")
    t.eq(domain.mail_sound("off"), nil)
    local sound = import("sound")
    local notes = {}
    sound.env.peripheral = t.fake_peripherals({
      speaker_0 = { types = { "speaker" }, methods = {
        playNote = function(_, _, pitch) notes[#notes + 1] = pitch end,
      } },
    })
    t.ok(sound.play(domain.mail_sound("note:chime"), { 18, 14 }))
    t.eq(table.concat(notes, ","), "18,14", "ding dong")
    sound.env.peripheral = t.fake_peripherals({})
    t.ok(not sound.play({ kind = "note", value = "bell" }), "no speaker, no sound")
  end)
end
