-- The domain directory and the controller's request handlers.
return function(t)
  local NOW = 1000
  local TODAY = 500

  -- A domain "home" with admin/secret, plus a computer "pc1" joined to it.
  -- `domain.disk_full = true` makes the storage report no room.
  local function new_domain()
    local import = t.fresh_import()
    local directory = import("directory")
    local dir = assert(directory.create("home", "admin", "secret"))
    local domain = { directory = directory, dir = dir, saves = 0, disk_full = false, day = TODAY }
    local storage = {
      save = function()
        domain.saves = domain.saves + 1
        return true
      end,
      has_room = function() return not domain.disk_full end,
      disk_status = function() return { free = 1234, capacity = 1000000 } end,
    }
    local clock = {
      now = function() return NOW end,
      today = function() return domain.day end,
    }
    domain.handlers = import("dc_handlers").new(dir, storage, clock)
    local joined = assert(domain.handlers.join({ sender = 7 }, {
      hostname = "pc1", admin_name = "admin", admin_password = "secret",
    }))
    domain.computer = { sender = 7, computer_token = joined.computer_token }
    return domain
  end

  local function login(domain, name, password)
    return domain.handlers.login(domain.computer, { name = name, password = password })
  end

  local function as_user(domain, session)
    return { sender = 7, computer_token = domain.computer.computer_token, token = session.token }
  end

  t.it("a new domain has the built-in groups and one admin", function()
    local domain = new_domain()
    local groups = {}
    for _, group in ipairs(domain.dir:list_groups()) do
      groups[group.name] = group
    end
    t.ok(groups["domain-admins"] and groups["domain-users"])
    t.ok(domain.dir:is_member("domain-admins", "admin"))
    t.ok(domain.dir:is_member("domain-users", "admin"), "every user is a domain user")
    t.ok(not domain.dir:remove_group("domain-admins"), "built-in groups stay")
    t.ok(not domain.dir:remove_user("admin"), "the last admin stays")
  end)

  t.it("any domain user can join computers (friends only)", function()
    local domain = new_domain()
    domain.dir:add_user("guest", "pw")
    local function join(name, password)
      return domain.handlers.join({ sender = 9 },
        { hostname = "pc9", admin_name = name, admin_password = password or "pw" })
    end
    t.ok(join("guest"), "a plain user may join")
    t.ok(not join("guest", "wrong"), "but needs the right password")
    t.ok(not join("nobody"))
  end)

  t.it("login, validate and logout need a joined computer", function()
    local domain = new_domain()
    t.ok(not domain.handlers.login({ sender = 3 }, { name = "admin", password = "secret" }),
      "unjoined computers cannot log users in")
    local session = assert(login(domain, "admin", "secret"))
    local user = domain.handlers.validate(domain.computer, { token = session.token })
    t.eq(user.name, "admin")
    domain.handlers.logout(domain.computer, { token = session.token })
    t.ok(not domain.handlers.validate(domain.computer, { token = session.token }))
    t.ok(not login(domain, "admin", "wrong"))
  end)

  t.it("tokens expire after their lifetime", function()
    local domain = new_domain()
    local session = domain.dir:login("admin", "secret", 0)
    t.ok(domain.dir:validate(session.token, domain.directory.SESSION_SECONDS - 1))
    t.ok(not domain.dir:validate(session.token, domain.directory.SESSION_SECONDS))
  end)

  t.it("disabling or removing a user ends their sessions", function()
    local domain = new_domain()
    domain.dir:add_user("bob", "pw")
    local session = domain.dir:login("bob", "pw", NOW)
    domain.dir:set_enabled("bob", false)
    t.ok(not domain.dir:validate(session.token, NOW))
    t.ok(not domain.dir:login("bob", "pw", NOW), "disabled users cannot log in")
  end)

  t.it("only domain admins can manage the directory", function()
    local domain = new_domain()
    domain.dir:add_user("bob", "pw")
    local bob = as_user(domain, login(domain, "bob", "pw"))
    local admin = as_user(domain, login(domain, "admin", "secret"))
    local _, err = domain.handlers.user_add(bob, { name = "eve", password = "x" })
    t.eq(err, "permission denied")
    t.ok(domain.handlers.user_add(admin, { name = "eve", password = "x" }))
    t.ok(domain.saves > 0, "changes are saved")
    t.ok(domain.handlers.list_users(bob), "everyone in the domain can read")
    t.ok(not domain.handlers.list_users({ sender = 7 }), "reading needs a login")
    t.ok(domain.handlers.user_passwd(bob, { name = "bob", password = "new" }),
      "users may change their own password")
    t.ok(not domain.handlers.user_passwd(bob, { name = "admin", password = "x" }))
  end)

  t.it("a computer can only update its own host record", function()
    local domain = new_domain()
    local reply = domain.handlers.host_update(domain.computer, {
      hostname = "pc1", info = { fuel = 10 }, kind = "turtle", version = "0.2.0",
    })
    t.eq(reply.hostname, "pc1")
    t.eq(domain.handlers.resolve(nil, { hostname = "pc1" }).id, 7)
    local hosts = domain.handlers.list_hosts()
    t.eq(hosts[1].info.fuel, 10)
    t.ok(not domain.handlers.host_update({ sender = 8, computer_token = "forged" },
      { hostname = "pc1" }), "unknown computers cannot update records")
  end)

  t.it("a rename moves the host record if the name is free", function()
    local domain = new_domain()
    domain.handlers.join({ sender = 8 },
      { hostname = "pc2", admin_name = "admin", admin_password = "secret" })
    t.eq(domain.handlers.host_update(domain.computer, { hostname = "storage" }).hostname, "storage")
    t.ok(not domain.handlers.resolve(nil, { hostname = "pc1" }))
    t.eq(domain.handlers.host_update(domain.computer, { hostname = "pc2" }).hostname, "storage",
      "a taken name is not stolen")
  end)

  t.it("a rename keeps the computer's service records working", function()
    local domain = new_domain()
    t.ok(domain.handlers.service_register(domain.computer, { type = "stock" }))
    domain.handlers.host_update(domain.computer, { hostname = "storage" })
    local found = domain.handlers.service_find(nil, { type = "stock" })
    t.eq(found.host, "storage")
    t.eq(found.id, 7)
  end)

  t.it("computers register their own service records; admins can add any", function()
    local domain = new_domain()
    domain.dir:add_user("bob", "pw")
    local bob = as_user(domain, login(domain, "bob", "pw"))
    local admin = as_user(domain, login(domain, "admin", "secret"))
    t.ok(not domain.handlers.service_add(bob, { type = "pkg", host = "pc1" }))
    local record = { type = "stock", protocol = "blockos.stock" }
    t.ok(domain.handlers.service_register(domain.computer, record))
    t.eq(domain.handlers.service_find(nil, { type = "stock" }).host, "pc1")
    t.ok(not domain.handlers.service_register({ sender = 3 }, { type = "x" }),
      "unjoined computers may not")
    local pkg_record = { type = "pkg", host = "pc1", protocol = "blockos.pkg" }
    t.ok(domain.handlers.service_add(admin, pkg_record))
    local found = domain.handlers.service_find(nil, { type = "pkg" })
    t.eq(found.id, 7)
    t.eq(found.protocol, "blockos.pkg")
    t.ok(not domain.handlers.service_add(admin, { type = "x", host = "unknown-host" }))
  end)

  t.it("computers remove only their own service records", function()
    local domain = new_domain()
    local joined = assert(domain.handlers.join({ sender = 8 },
      { hostname = "pc2", admin_name = "admin", admin_password = "secret" }))
    local pc2 = { sender = 8, computer_token = joined.computer_token }
    t.ok(domain.handlers.service_register(domain.computer, { type = "stock" }))
    t.ok(domain.handlers.service_register(pc2, { type = "pkg" }))

    t.ok(not domain.handlers.service_unregister(pc2, { type = "stock" }),
      "another computer's record stays")
    t.ok(not domain.handlers.service_unregister({ sender = 3 }, { type = "stock" }),
      "unjoined computers may not")
    t.ok(domain.handlers.service_unregister(domain.computer, { type = "stock" }))
    t.ok(not domain.handlers.service_find(nil, { type = "stock" }))
    t.eq(domain.handlers.service_find(nil, { type = "pkg" }).host, "pc2")
    t.ok(not domain.handlers.service_unregister(domain.computer, { type = "stock" }),
      "a missing record is an error")
  end)

  t.it("validate_computer tells a service which computer is calling", function()
    local domain = new_domain()
    local reply = domain.handlers.validate_computer(domain.computer,
      { computer_token = domain.computer.computer_token })
    t.eq(reply.hostname, "pc1")
    t.ok(not domain.handlers.validate_computer(domain.computer, { computer_token = "nope" }))
  end)

  t.it("removing a computer revokes its token and its service records", function()
    local domain = new_domain()
    domain.dir:add_service("pkg", "pc1", "blockos.pkg")
    local admin = as_user(domain, login(domain, "admin", "secret"))
    t.ok(domain.handlers.computer_remove(admin, { hostname = "pc1" }))
    t.ok(not domain.dir:computer_by_token(domain.computer.computer_token))
    t.ok(not domain.dir:find_service("pkg"))
  end)

  t.it("status reports stay in memory and are capped in size", function()
    local domain = new_domain()
    local report = { hostname = "pc1", info = { fuel = 42 }, kind = "turtle" }
    t.ok(domain.handlers.host_update(domain.computer, report))
    t.eq(domain.dir.data.computers.pc1.info, nil, "info must not be saved")
    t.eq(domain.handlers.list_hosts()[1].info.fuel, 42)

    local huge = { blob = string.rep("x", 2000) }
    local ok, err = domain.handlers.host_update(domain.computer, { hostname = "pc1", info = huge })
    t.ok(not ok)
    t.ok(err:find("too large"), err)
  end)

  t.it("status reports only save on a rename, a new ID or a new day", function()
    local domain = new_domain()
    domain.handlers.host_update(domain.computer, { hostname = "pc1" })
    local saves = domain.saves
    domain.handlers.host_update(domain.computer, { hostname = "pc1", info = { fuel = 1 } })
    t.eq(domain.saves, saves, "a plain heartbeat must not write to disk")
    domain.day = TODAY + 1
    domain.handlers.host_update(domain.computer, { hostname = "pc1" })
    t.eq(domain.saves, saves + 1, "the first report of a day is saved")
  end)

  t.it("computers unseen for a week are marked stale", function()
    local domain = new_domain()
    domain.handlers.host_update(domain.computer, { hostname = "pc1" })
    domain.day = TODAY + domain.directory.STALE_DAYS
    local host = domain.handlers.list_hosts()[1]
    t.eq(host.days_unseen, domain.directory.STALE_DAYS)
    t.ok(host.is_stale)
  end)

  t.it("a full disk refuses changes but logins and lookups keep working", function()
    local domain = new_domain()
    local admin = as_user(domain, login(domain, "admin", "secret"))
    domain.disk_full = true
    local _, err = domain.handlers.user_add(admin, { name = "eve", password = "x" })
    t.ok(err:find("disk is full"), err)
    t.eq(domain.dir.data.users.eve, nil, "nothing changes when it cannot be saved")
    t.ok(login(domain, "admin", "secret"), "logins still work")
    t.ok(domain.handlers.resolve(nil, { hostname = "pc1" }), "lookups still work")
    t.ok(domain.handlers.host_update(domain.computer, { hostname = "pc1" }),
      "status reports still work")
  end)

  t.it("dc_status reports counts and disk space", function()
    local domain = new_domain()
    local admin = as_user(domain, login(domain, "admin", "secret"))
    local status = domain.handlers.dc_status(admin)
    t.eq(status.domain, "home")
    t.eq(status.users, 1)
    t.eq(status.computers, 1)
    t.eq(status.free, 1234)
    t.ok(status.saved_bytes > 0)
  end)

  t.it("expired sessions are pruned", function()
    local domain = new_domain()
    domain.dir:login("admin", "secret", 0)
    t.eq(domain.dir:prune_sessions(domain.directory.SESSION_SECONDS), 1)
    t.eq(domain.dir:stats().sessions, 0)
  end)

  t.it("sessions survive a controller restart", function()
    local domain = new_domain()
    local session = login(domain, "admin", "secret")
    local saved = textutils.unserialise(textutils.serialise(domain.dir:saved_sessions()))
    local restarted = domain.directory.load(domain.dir.data, saved)
    t.eq(restarted:validate(session.token, NOW).name, "admin")
  end)

  t.it("a logged-in user can take a computer out of the domain without a password", function()
    local domain = new_domain()
    local session = login(domain, "admin", "secret")
    local ctx = as_user(domain, session)
    t.ok(domain.handlers.leave(ctx, {}))
    t.ok(not domain.dir:computer_by_token(domain.computer.computer_token))
  end)

  -- Managed mode ---------------------------------------------------------------

  t.it("an everyone group includes every user, also ones added later", function()
    local domain = new_domain()
    local admin = as_user(domain, login(domain, "admin", "secret"))
    t.ok(domain.handlers.group_add(admin, { name = "turtle-drivers", everyone = true }))
    domain.dir:add_user("carol", "pw")
    t.ok(domain.dir:is_member("turtle-drivers", "carol"), "added after the group")
    local carol = login(domain, "carol", "pw")
    local found = false
    for _, group in ipairs(carol.groups) do
      found = found or group == "turtle-drivers"
    end
    t.ok(found, "logins carry everyone groups")
    t.ok(domain.handlers.group_set_everyone(admin, { group = "turtle-drivers", everyone = false }))
    t.ok(not domain.dir:is_member("turtle-drivers", "carol"))
  end)

  t.it("a module's admins manage its roles without a domain admin", function()
    local domain = new_domain()
    domain.dir:add_user("alice", "pw")
    domain.dir:add_user("bob", "pw")
    local admin = as_user(domain, login(domain, "admin", "secret"))
    t.ok(domain.handlers.group_add(admin,
      { name = "logistics-admins", managed_by = "logistics-admins" }))
    t.ok(domain.handlers.group_addmember(admin, { group = "logistics-admins", user = "alice" }))
    t.ok(domain.handlers.group_add(admin,
      { name = "logistics-users", everyone = true, managed_by = "logistics-admins" }))

    local alice = as_user(domain, login(domain, "alice", "pw"))
    local bob = as_user(domain, login(domain, "bob", "pw"))
    t.ok(domain.handlers.group_set_everyone(alice, { group = "logistics-users", everyone = false }))
    t.ok(domain.handlers.group_addmember(alice, { group = "logistics-users", user = "bob" }))
    t.ok(not domain.handlers.group_addmember(bob, { group = "logistics-users", user = "bob" }),
      "bob is not a logistics admin")
    t.ok(not domain.handlers.group_addmember(alice, { group = "domain-admins", user = "alice" }),
      "module admins can't touch other groups")

    t.ok(domain.handlers.group_add(alice,
      { name = "logistics-node-ars", managed_by = "logistics-admins" }), "a role per node")
    t.ok(not domain.handlers.group_add(alice,
      { name = "pkg-secret", managed_by = "logistics-admins" }),
      "only roles of their own module")
    t.ok(not domain.handlers.group_add(alice, { name = "logistics-x" }), "must be managed by them")
    t.ok(not domain.handlers.group_set_manager(alice, { group = "logistics-users" }),
      "only domain admins change who manages a group")
  end)

  t.it("modules read role info with the computer's own token", function()
    local domain = new_domain()
    local admin = as_user(domain, login(domain, "admin", "secret"))
    domain.handlers.group_add(admin, { name = "turtle-drivers", everyone = true })
    local info = domain.handlers.group_get(domain.computer, { name = "turtle-drivers" })
    t.eq(info.everyone, true)
    local missing, err = domain.handlers.group_get(domain.computer, { name = "logistics-users" })
    t.ok(not missing)
    t.eq(err, "no such group", "a module that is not set up")
    t.ok(not domain.handlers.group_get({ sender = 3 }, { name = "turtle-drivers" }),
      "unjoined computers may not ask")
  end)

  -- Computer roles -------------------------------------------------------------

  t.it("computer roles merge into what a computer should have", function()
    local domain = new_domain()
    local admin = as_user(domain, login(domain, "admin", "secret"))
    t.ok(domain.handlers.computer_role_set(admin, { name = "logistics-node",
      packages = { "logistics-node", "logistics" } }))
    t.ok(domain.handlers.computer_role_set(admin, { name = "farm-display", packages = { "music" },
      settings = { ["blockos.autologin"] = "farmer", ["blockos.logistics.board"] = "monitor_0" } }))
    t.ok(domain.handlers.computer_assign(admin,
      { hostname = "pc1", roles = { "logistics-node", "farm-display" } }))

    local config = domain.handlers.computer_config(domain.computer, {})
    t.eq(table.concat(config.packages, ","), "logistics,logistics-node,music")
    t.eq(config.settings["blockos.autologin"], "farmer")
    t.ok(not domain.handlers.computer_config({ sender = 3 }, {}), "only joined computers ask")

    local roles = domain.handlers.list_computer_roles(admin, {})
    t.eq(roles[1].name, "farm-display")
    t.eq(roles[1].computers[1], "pc1")
    t.eq(domain.handlers.list_hosts()[1].roles[2], "farm-display")
  end)

  t.it("computer roles are checked and only admins change them", function()
    local domain = new_domain()
    domain.dir:add_user("bob", "pw")
    local admin = as_user(domain, login(domain, "admin", "secret"))
    local bob = as_user(domain, login(domain, "bob", "pw"))
    t.ok(not domain.handlers.computer_role_set(bob, { name = "x", packages = {} }),
      "bob is no admin")
    t.ok(not domain.handlers.computer_role_set(admin,
      { name = "bad", packages = {}, settings = { ["shell.allow_disk_startup"] = false } }),
      "only blockos.* settings")
    t.ok(not domain.handlers.computer_assign(admin, { hostname = "pc1", roles = { "missing" } }))
    t.ok(domain.handlers.computer_role_set(admin, { name = "media", packages = { "music" } }))
    t.ok(domain.handlers.computer_assign(admin, { hostname = "pc1", roles = { "media" } }))
    t.ok(domain.handlers.computer_role_del(admin, { name = "media" }))
    local after = domain.handlers.computer_config(domain.computer, {})
    t.eq(#after.packages, 0, "taken off the computer")
  end)
end
