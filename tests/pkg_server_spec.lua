-- The package server: storage across drives, access rules, and installing from it.
return function(t)
  local ME = os.getComputerID()

  local function encode(import, name, version, files, extra)
    local pkg = import("pkg")
    local manifest = { name = name, version = version }
    for key, value in pairs(extra or {}) do
      manifest[key] = value
    end
    files = files or { ["blockos/lib/" .. name .. ".lua"] = "return {}" }
    return pkg.encode({ manifest = manifest, files = files })
  end

  -- Two directories stand in for two disk drives.
  local function new_repo()
    local import = t.fresh_import()
    local repo = import("repo")
    local drives = { t.sandbox .. "/drive1", t.sandbox .. "/drive2" }
    for _, drive in ipairs(drives) do
      fs.makeDir(drive)
    end
    repo.set_roots(drives)
    local rpc = import("rpc")
    rpc.set_user_validator(function(token)
      local users = {
        admin = { name = "admin", groups = { "domain-users", "domain-admins" } },
        engineer = { name = "eng", groups = { "domain-users", "engineers" } },
        guest = { name = "guest", groups = { "domain-users" } },
      }
      return users[token]
    end)
    return import, repo, rpc
  end

  t.it("stores packages on drives and finds them again", function()
    local import, repo = new_repo()
    t.ok(repo.store(encode(import, "alpha", "1.0.0")))
    t.ok(repo.store(encode(import, "beta", "1.0.0")))
    local stored = repo.scan()
    t.ok(stored.alpha and stored.beta)
    t.ok(repo.read("alpha"), "package bytes missing")
    t.ok(repo.store(encode(import, "alpha", "1.1.0")), "replacing a package")
    t.eq(repo.scan().alpha.version, "1.1.0")
    t.ok(not repo.store("not a package"))
  end)

  t.it("a missing drive only hides its own packages", function()
    local import, repo = new_repo()
    repo.store(encode(import, "alpha", "1.0.0"))
    local where = repo.scan().alpha.root
    fs.delete(where)
    t.eq(repo.scan().alpha, nil)
    t.ok(repo.store(encode(import, "beta", "1.0.0")), "the other drive still works")
  end)

  t.it("restricted packages are hidden and refused without the group", function()
    local import, repo = new_repo()
    repo.store(encode(import, "public-tool", "1.0.0"))
    repo.store(encode(import, "secret-tool", "1.0.0"))
    repo.set_rule("secret-tool", { "engineers" })
    local handlers = repo.handlers()

    t.ok(handlers.index({}).packages["public-tool"])
    t.eq(handlers.index({}).packages["secret-tool"], nil, "hidden from anonymous callers")
    t.eq(handlers.index({ token = "guest" }).packages["secret-tool"], nil)
    t.ok(handlers.index({ token = "engineer" }).packages["secret-tool"])

    t.ok(handlers.fetch({}, { name = "public-tool" }))
    local _, err = handlers.fetch({}, { name = "secret-tool" })
    t.eq(err, "login required")
    _, err = handlers.fetch({ token = "guest" }, { name = "secret-tool" })
    t.eq(err, "permission denied")
    t.ok(handlers.fetch({ token = "engineer" }, { name = "secret-tool" }))
  end)

  t.it("publishing needs a domain admin and a valid package", function()
    local import, repo = new_repo()
    local handlers = repo.handlers()
    local raw = encode(import, "tool", "2.0.0")
    t.ok(not handlers.publish({ token = "guest" }, { raw = raw }))
    t.ok(not handlers.publish({ token = "admin" }, { raw = "garbage" }))
    local result = handlers.publish({ token = "admin" }, { raw = raw })
    t.eq(result.name, "tool")
    t.ok(repo.scan().tool)
  end)

  t.it("pkg installs from the server over rpc", function()
    local import, repo, rpc = new_repo()
    local core_files = { ["blockos/boot.lua"] = "-- boot", ["blockos/kernel/x.lua"] = "return 1" }
    repo.store(encode(import, "core", "1.0.0", core_files))
    repo.store(encode(import, "tool", "1.0.0", nil, { optional = true }))
    local pkg = import("pkg")
    local source = import("pkg_remote").source(ME, "test server")

    rpc.set_transport(rpc.loopback_transport())
    parallel.waitForAny(
      function() rpc.serve("blockos.pkg", repo.handlers()) end,
      function()
        local index = assert(source.index())
        local names = assert(pkg.select(index, { "tool" }))
        local fetched, packages = pkg.fetch(source, nil, names)
        t.ok(fetched, packages)
        t.ok(pkg.apply(packages))
      end
    )
    t.ok(pkg.installed().tool, "tool not installed")
    t.eq(pkg.installed_version(), "1.0.0")
  end)
end
