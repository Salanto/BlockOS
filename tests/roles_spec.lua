-- Module roles: standalone, not set up, and managed mode; guided setup planning.
return function(t)
  local DRIVERS = {
    { name = "turtle-drivers", default = "everyone", description = "drive turtles" },
  }
  local LOGISTICS = {
    { name = "logistics-admins", default = "installer" },
    { name = "logistics-users", default = "everyone" },
  }

  -- roles with a fake directory: `groups` maps role name -> info (missing = not set up).
  local function new_roles(options)
    local roles = t.fresh_import()("roles")
    roles.env = {
      is_joined = function() return options.joined ~= false end,
      group_get = function(name)
        local info = (options.groups or {})[name]
        if info then
          return info
        end
        return nil, "no such group"
      end,
      require_user = function(ctx, groups)
        local user = (options.users or {})[ctx.token]
        if not user then
          return nil, "login required"
        end
        for _, group in ipairs(user.groups) do
          if group == groups[1] then
            return user
          end
        end
        return nil, "permission denied"
      end,
      installed = function() return options.installed or {} end,
      clock = function() return 0 end,
    }
    return roles
  end

  t.it("without a domain everything is open", function()
    local roles = new_roles({
      joined = false,
      installed = { ["turtle-remote"] = { roles = DRIVERS } },
    })
    t.eq(roles.mode("turtle-remote"), "standalone")
    t.ok(roles.allows({}, "turtle-drivers"))
    t.eq(#roles.pending(), 0)
  end)

  t.it("joined but not set up: still open, and listed as pending", function()
    local roles = new_roles({ installed = { ["turtle-remote"] = { roles = DRIVERS }, core = {} } })
    t.eq(roles.mode("turtle-remote"), "unconfigured")
    t.ok(roles.allows({}, "turtle-drivers"), "joining never locks anyone out")
    t.eq(roles.pending()[1], "turtle-remote")
    t.eq(roles.mode("core"), "standalone", "packages without roles are never managed")
  end)

  t.it("managed: users need the role; computers only where it is open", function()
    local roles = new_roles({
      installed = { ["turtle-remote"] = { roles = DRIVERS } },
      groups = { ["turtle-drivers"] = { name = "turtle-drivers", everyone = false } },
      users = {
        alice = { name = "alice", groups = { "domain-users", "turtle-drivers" } },
        bob = { name = "bob", groups = { "domain-users" } },
      },
    })
    t.eq(roles.mode("turtle-remote"), "managed")
    t.ok(roles.allows({ token = "alice" }, "turtle-drivers"))
    local ok, err = roles.allows({ token = "bob" }, "turtle-drivers")
    t.ok(not ok)
    t.eq(err, "permission denied")
    t.ok(not roles.allows({ computer_token = "x" }, "turtle-drivers"), "no user, role not open")
    t.ok(roles.allows({ local_admin = true }, "turtle-drivers"),
      "the local keyboard can always fix it")
  end)

  t.it("a role open to everyone lets a computer's service in", function()
    local roles = new_roles({
      groups = { ["turtle-drivers"] = { name = "turtle-drivers", everyone = true } },
    })
    t.ok(roles.allows({ computer_token = "x" }, "turtle-drivers"))
  end)

  t.it("guided setup plans friendly defaults and the module admin as manager", function()
    local roles = new_roles({})
    local plan = roles.plan(LOGISTICS, "root")
    local by_name = {}
    for _, entry in ipairs(plan) do
      by_name[entry.name] = entry
    end
    t.eq(by_name["logistics-admins"].members[1], "root",
      "admins: the domain admin running setup")
    t.eq(by_name["logistics-users"].everyone, true, "users: everyone")
    t.eq(by_name["logistics-users"].managed_by, "logistics-admins")
    t.eq(by_name["logistics-admins"].managed_by, "logistics-admins",
      "the admin role manages itself")

    local typed = roles.plan(LOGISTICS, "root", { ["logistics-users"] = "alice, bob" })
    for _, entry in ipairs(typed) do
      if entry.name == "logistics-users" then
        t.eq(entry.everyone, false)
        t.eq(#entry.members, 2)
      end
    end
  end)

  t.it("setup creates the admin role first, then the others with their members", function()
    local roles = new_roles({})
    local calls = {}
    local report = roles.apply(roles.plan(LOGISTICS, "root", { ["logistics-users"] = "bob" }),
      function(op, call_args)
        local target = call_args.name or call_args.group
        calls[#calls + 1] = op .. ":" .. target .. ":" .. tostring(call_args.user)
        return true
      end)
    t.eq(calls[1], "group_add:logistics-admins:nil")
    t.eq(calls[2], "group_addmember:logistics-admins:root")
    t.eq(calls[3], "group_add:logistics-users:nil")
    t.eq(calls[4], "group_addmember:logistics-users:bob")
    t.eq(#report, 2)
  end)
end
