-- End to end: build the release, install it from the disk image, upgrade it,
-- and talk to a second emulated computer over rednet.
return function(t)
  local function build(version, out_dir)
    t.ok(shell.run(fs.combine(t.repo, "tools/build.lua"), version, out_dir, t.repo),
      "build " .. version .. " failed")
  end

  local function run_disk_installer(disk_dir, action)
    return shell.run(fs.combine(disk_dir, "startup.lua"),
      "--action", action, "--dir", disk_dir, "--prefix", t.sandbox,
      "--admin", "admin", "secret")
  end

  t.it("the build produces loadable packages and a floppy-sized disk", function()
    local out = t.sandbox .. "/dist"
    build("0.1.0", out)
    local index = textutils.unserialise(t.read(out .. "/index.lua"))
    t.eq(index.version, "0.1.0")
    t.ok(index.packages.core and index.packages.net, "core and net expected in the index")
    local import = t.fresh_import()
    local pkg = import("pkg")
    for name, entry in pairs(index.packages) do
      local raw = t.read(out .. "/" .. name .. ".pkg")
      t.ok(pkg.verify(raw, entry), name .. " does not match the index")
      t.ok(pkg.decode(raw), name .. " does not decode")
    end
    t.ok(fs.exists(out .. "/disk/startup.lua"))
    t.ok(fs.exists(out .. "/install.lua"))
  end)

  t.it("installs from the disk image, then upgrades and keeps the accounts", function()
    local out1, out2 = t.sandbox .. "/dist1", t.sandbox .. "/dist2"
    build("0.1.0", out1)
    build("0.2.0", out2)

    t.ok(run_disk_installer(out1 .. "/disk", "install"), "install failed")
    local import = t.fresh_import()
    local pkg, auth, paths = import("pkg"), import("auth"), import("paths")
    t.eq(pkg.installed_version(), "0.1.0")
    t.ok(pkg.installed().net, "net package missing")
    t.ok(pkg.has_loader(), "loader not installed")
    t.ok(auth.check("admin", "secret"), "admin account missing")

    auth.add_user("guest", "pw", false)
    t.ok(run_disk_installer(out2 .. "/disk", "upgrade"), "upgrade failed")
    t.eq(pkg.installed_version(), "0.2.0")
    t.ok(auth.check("guest", "pw"), "accounts lost in the upgrade")
    t.ok(fs.exists(paths.previous() .. "/boot.lua"), "previous version not kept")

    t.ok(run_disk_installer(out2 .. "/disk", "rollback"), "rollback failed")
    t.eq(pkg.installed_version(), "0.1.0")
  end)

  t.it("the installed kernel modules load with the boot loader's import", function()
    build("0.1.0", t.sandbox .. "/dist")
    t.ok(run_disk_installer(t.sandbox .. "/dist/disk", "install"))
    local root = t.sandbox .. "/blockos"
    for _, dir in ipairs({ "kernel", "lib", "services", "bin" }) do
      for _, file in ipairs(fs.list(fs.combine(root, dir))) do
        local chunk, err = loadfile(fs.combine(root, dir .. "/" .. file))
        t.ok(chunk, err)
      end
    end
  end)

  t.it("finds a second computer over rednet (CraftOS-PC only)", function()
    if not periphemu then
      t.skip("needs CraftOS-PC's periphemu")
    end
    -- tools/craftos-run.sh prepares computer 1 with tests/fixtures/peer_startup.lua.
    periphemu.create("top", "modem")
    rednet.open("top")
    periphemu.create(1, "computer")

    local sender, message = rednet.receive("blockos.announce", 15)
    t.eq(sender, 1, "no announce from the peer computer")

    local net = t.fresh_import()("net")
    net.reset()
    t.ok(net.handle_announce(sender, message), "peer announce is not valid")
    t.eq(net.resolve("peer-one"), 1)
    t.eq(rednet.lookup("blockos", "peer-one"), 1, "rednet.lookup did not find the peer")

    local hosted = pcall(rednet.host, "blockos", "peer-one")
    t.ok(not hosted, "hosting a name in use should fail")

    rednet.close("top")
    periphemu.remove("top")
  end)
end
