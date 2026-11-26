-- The domain directory and the controller's request handlers.
return function(t)
  local NOW = 1000

  -- A domain "home" with admin/secret, plus a computer "pc1" joined to it.
  local function new_domain()
    local import = t.fresh_import()
    local directory = import("directory")
    local dir = assert(directory.create("home", "admin", "secret"))
    local saves = 0
    local handlers = import("dc_handlers").new(dir, function() saves = saves + 1 end,
      function() return NOW end)
    local joined = assert(handlers.join({ sender = 7 }, {
      hostname = "pc1", admin_name = "admin", admin_password = "secret",
    }))
    local computer = { sender = 7, computer_token = joined.computer_token }
    return {
      directory = directory,
      dir = dir,
      handlers = handlers,
      computer = computer,
      saves = function() return saves end,
    }
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
    t.ok(groups["domain-admins"] and groups["domain-users"] and groups["computer-joiners"])
    t.ok(domain.dir:is_member("domain-admins", "admin"))
    t.ok(domain.dir:is_member("domain-users", "admin"), "every user is a domain user")
    t.ok(not domain.dir:remove_group("domain-admins"), "built-in groups stay")
    t.ok(not domain.dir:remove_user("admin"), "the last admin stays")
  end)

  t.it("only admins and computer-joiners can join computers", function()
    local domain = new_domain()
    domain.dir:add_user("joiner", "pw")
    domain.dir:add_user("guest", "pw")
    domain.dir:add_member("computer-joiners", "joiner")
    local function join(name)
      return domain.handlers.join({ sender = 9 },
        { hostname = "pc9", admin_name = name, admin_password = "pw" })
    end
    t.ok(join("joiner"), "a computer-joiner may join")
    t.ok(not join("guest"), "a plain user may not")
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
    t.ok(domain.saves() > 0, "changes are saved")
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

  t.it("service records need domain-admins or dns-admins", function()
    local domain = new_domain()
    domain.dir:add_user("dns", "pw")
    domain.dir:add_member("dns-admins", "dns")
    domain.dir:add_user("bob", "pw")
    local dns = as_user(domain, login(domain, "dns", "pw"))
    local bob = as_user(domain, login(domain, "bob", "pw"))
    t.ok(not domain.handlers.service_add(bob, { type = "pkg", host = "pc1" }))
    t.ok(domain.handlers.service_add(dns, { type = "pkg", host = "pc1", protocol = "blockos.pkg" }))
    local found = domain.handlers.service_find(nil, { type = "pkg" })
    t.eq(found.id, 7)
    t.eq(found.protocol, "blockos.pkg")
    t.ok(not domain.handlers.service_add(dns, { type = "x", host = "unknown-host" }))
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
end
