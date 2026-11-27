-- Versions, package files, install/upgrade/remove and rollback.
return function(t)
  local function make_package(import, name, version, files, extra)
    local pkg = import("pkg")
    local bundle = { manifest = { name = name, version = version }, files = files }
    for key, value in pairs(extra or {}) do
      bundle.manifest[key] = value
    end
    return pkg.decode(pkg.encode(bundle))
  end

  local function core_package(import, version, extra_files)
    local files = {
      ["blockos/boot.lua"] = "-- boot " .. version,
      ["blockos/kernel/a.lua"] = "return 1",
    }
    for path, content in pairs(extra_files or {}) do
      files[path] = content
    end
    return make_package(import, "core", version, files)
  end

  t.it("compare_versions orders releases and prereleases", function()
    local pkg = t.fresh_import()("pkg")
    t.eq(pkg.compare_versions("0.1.0", "0.1.0"), 0)
    t.eq(pkg.compare_versions("0.2.0", "0.10.0"), -1)
    t.eq(pkg.compare_versions("v1.0.0", "0.9.9"), 1)
    t.eq(pkg.compare_versions("0.1.0-rc1", "0.1.0"), -1)
    t.eq(pkg.compare_versions("0.1.0-rc2", "0.1.0-rc1"), 1)
  end)

  t.it("satisfies understands ranges", function()
    local pkg = t.fresh_import()("pkg")
    t.ok(pkg.satisfies("0.2.0", ">=0.1"))
    t.ok(not pkg.satisfies("0.0.9", ">=0.1"))
    t.ok(pkg.satisfies("0.1.0-rc1", ">=0.1.0-0"))
    t.ok(pkg.satisfies("1.0.0", "*"))
    t.ok(pkg.satisfies("0.3.0", "0.3.0"))
    t.ok(not pkg.satisfies("0.3.1", "<0.3"))
  end)

  t.it("verify catches size and checksum mismatches", function()
    local pkg = t.fresh_import()("pkg")
    local raw = "some package bytes"
    t.ok(pkg.verify(raw, { size = #raw, sum = pkg.checksum(raw) }))
    t.ok(not pkg.verify(raw, { size = #raw + 1 }))
    t.ok(not pkg.verify(raw, { sum = pkg.checksum(raw) + 1 }))
  end)

  t.it("decode rejects malformed packages", function()
    local pkg = t.fresh_import()("pkg")
    t.ok(not pkg.decode("nonsense"))
    t.ok(not pkg.decode(textutils.serialise({ manifest = { name = "x" }, files = {} })))
    local escaping = { manifest = { name = "x", version = "1" }, files = { ["../evil"] = "" } }
    t.ok(not pkg.decode(textutils.serialise(escaping)))
  end)

  t.it("apply installs a fresh tree with its package database", function()
    local import = t.fresh_import()
    local pkg, paths = import("pkg"), import("paths")
    t.ok(pkg.apply({ core_package(import, "0.1.0") }))
    t.eq(t.read(paths.root() .. "/boot.lua"), "-- boot 0.1.0")
    t.eq(pkg.installed_version(), "0.1.0")
    t.ok(not fs.exists(paths.staging()), "staging left behind")
    t.ok(not fs.exists(paths.upgrade_state()), "state marker left behind")
  end)

  t.it("upgrade keeps the old version and removes stale files", function()
    local import = t.fresh_import()
    local pkg, paths = import("pkg"), import("paths")
    pkg.apply({ core_package(import, "0.1.0", { ["blockos/kernel/old.lua"] = "return 0" }) })
    t.ok(pkg.apply({ core_package(import, "0.2.0") }))
    t.eq(pkg.installed_version(), "0.2.0")
    t.ok(not fs.exists(paths.root() .. "/kernel/old.lua"), "stale file kept")
    t.eq(t.read(paths.previous() .. "/boot.lua"), "-- boot 0.1.0")
  end)

  t.it("files outside /blockos are only written when missing", function()
    local import = t.fresh_import()
    local pkg, paths = import("pkg"), import("paths")
    local defaults = { ["etc/blockos/motd"] = "default" }
    pkg.apply({ core_package(import, "0.1.0", defaults) })
    t.eq(t.read(paths.top("etc/blockos/motd")), "default")
    t.write(paths.top("etc/blockos/motd"), "edited by the user")
    pkg.apply({ core_package(import, "0.2.0", defaults) })
    t.eq(t.read(paths.top("etc/blockos/motd")), "edited by the user")
  end)

  t.it("apply refuses a package whose Lua does not compile", function()
    local import = t.fresh_import()
    local pkg, paths = import("pkg"), import("paths")
    pkg.apply({ core_package(import, "0.1.0") })
    local bad_file = { ["blockos/kernel/bad.lua"] = "this is not lua (" }
    local broken = core_package(import, "0.2.0", bad_file)
    local ok, err = pkg.apply({ broken })
    t.ok(not ok)
    t.ok(err:find("broken file"), err)
    t.eq(pkg.installed_version(), "0.1.0")
    t.ok(not fs.exists(paths.staging()))
  end)

  t.it("apply refuses unmet dependencies", function()
    local import = t.fresh_import()
    local pkg = import("pkg")
    local core = core_package(import, "0.1.0")
    local addon_files = { ["blockos/lib/addon.lua"] = "return {}" }
    local addon = make_package(import, "addon", "0.1.0", addon_files,
      { depends = { core = ">=0.5" } })
    local ok, err = pkg.apply({ core, addon })
    t.ok(not ok)
    t.ok(err:find("needs core"), err)
  end)

  t.it("installing an optional package keeps the others; remove takes it out", function()
    local import = t.fresh_import()
    local pkg, paths = import("pkg"), import("paths")
    pkg.apply({ core_package(import, "0.1.0") })
    local addon_files = { ["blockos/lib/addon.lua"] = "return {}" }
    local addon = make_package(import, "addon", "0.1.0", addon_files,
      { depends = { core = ">=0.1" }, optional = true })
    t.ok(pkg.apply({ addon }))
    t.ok(pkg.installed().addon)
    t.ok(fs.exists(paths.root() .. "/boot.lua"), "core files lost")
    t.ok(pkg.apply({}, { remove = { "addon" } }))
    t.eq(pkg.installed().addon, nil)
    t.ok(not fs.exists(paths.root() .. "/lib/addon.lua"))
    t.ok(not pkg.apply({}, { remove = { "core" } }), "core must not be removable")
  end)

  t.it("a package that replaces another removes it but keeps shared files", function()
    local import = t.fresh_import()
    local pkg, paths = import("pkg"), import("paths")
    pkg.apply({ core_package(import, "0.1.0") })
    local shared = "blockos/lib/storage_sources/inventory.lua"
    local old = make_package(import, "old-monitor", "0.1.0",
      { [shared] = "return 1", ["blockos/bin/stock.lua"] = "print(1)" },
      { depends = { core = ">=0.1" }, optional = true })
    t.ok(pkg.apply({ old }))
    local new = make_package(import, "new-node", "0.2.0",
      { [shared] = "return 2" },
      { depends = { core = ">=0.1" }, optional = true, replaces = { "old-monitor" } })
    t.ok(pkg.apply({ new }))
    t.eq(pkg.installed()["old-monitor"], nil, "the replaced package is gone")
    t.ok(not fs.exists(paths.root() .. "/bin/stock.lua"))
    t.ok(fs.exists(paths.root() .. "/lib/storage_sources/inventory.lua"), "the shared file stays")
  end)

  t.it("select picks required, installed and requested packages with dependencies", function()
    local import = t.fresh_import()
    local pkg = import("pkg")
    local index = { packages = {
      core = { version = "1" },
      net = { version = "1", depends = { core = "*" } },
      server = { version = "1", optional = true, depends = { lib = "*" } },
      lib = { version = "1", optional = true },
      other = { version = "1", optional = true },
    } }
    local names = pkg.select(index)
    t.eq(table.concat(names, ","), "core,net")
    names = pkg.select(index, { "server" })
    t.eq(table.concat(names, ","), "core,lib,net,server")
    t.ok(not pkg.select(index, { "missing" }))
  end)

  t.it("rollback swaps the current and previous versions", function()
    local import = t.fresh_import()
    local pkg = import("pkg")
    t.ok(not pkg.rollback(), "rollback without a previous version")
    pkg.apply({ core_package(import, "0.1.0") })
    pkg.apply({ core_package(import, "0.2.0") })
    t.ok(pkg.rollback())
    t.eq(pkg.installed_version(), "0.1.0")
    t.ok(pkg.rollback())
    t.eq(pkg.installed_version(), "0.2.0")
  end)

  t.it("install_loader backs up a foreign startup", function()
    local import = t.fresh_import()
    local pkg, paths = import("pkg"), import("paths")
    t.write(paths.startup(), "print('another OS')")
    t.write(paths.startup_dir() .. "/10_thing.lua", "print('x')")
    local note = pkg.install_loader("-- BlockOS loader\n")
    t.ok(note, "expected a note about the backup")
    t.ok(pkg.has_loader())
    t.eq(t.read(paths.startup_backup() .. "/startup.lua"), "print('another OS')")
    t.ok(fs.exists(paths.startup_backup() .. "/startup/10_thing.lua"))
    t.eq(pkg.install_loader("-- BlockOS loader\n"), nil, "reinstalling should not back up")
  end)

  t.it("an exclusive package refuses other optional packages unless forced", function()
    local import = t.fresh_import()
    local pkg = import("pkg")
    pkg.apply({ core_package(import, "0.1.0") })
    local lib_files = { ["blockos/lib/dc.lua"] = "return {}" }
    local controller = make_package(import, "controller", "0.1.0", lib_files,
      { optional = true, exclusive = true, depends = { helper = "*" } })
    local helper_files = { ["blockos/lib/helper.lua"] = "return {}" }
    local helper = make_package(import, "helper", "0.1.0", helper_files,
      { optional = true })
    local other_files = { ["blockos/lib/other.lua"] = "return {}" }
    local other = make_package(import, "other", "0.1.0", other_files,
      { optional = true })

    t.ok(pkg.apply({ helper, controller }), "its own dependencies are allowed")
    local ok, err = pkg.apply({ other })
    t.ok(not ok, "another optional package next to it")
    t.ok(err:find("must run alone"), err)
    t.ok(pkg.apply({ other }, { force = true }), "--force allows it")
  end)

  t.it("media-only files stay in the package but are not installed", function()
    local import = t.fresh_import()
    local pkg, paths = import("pkg"), import("paths")
    local files = {
      ["blockos/boot.lua"] = "-- boot",
      ["blockos/loader.lua"] = "-- BlockOS loader",
      ["blockos/installer/disk.lua"] = "-- installer",
    }
    local core = make_package(import, "core", "0.1.0", files,
      { media_only = { "blockos/installer/", "blockos/loader.lua" } })
    t.ok(pkg.apply({ core }))
    t.ok(fs.exists(paths.root() .. "/boot.lua"))
    t.ok(not fs.exists(paths.root() .. "/loader.lua"), "loader copy installed")
    t.ok(not fs.exists(paths.root() .. "/installer"), "installer copy installed")
    t.ok(core.files["blockos/installer/disk.lua"], "the package itself keeps the file")
  end)

  t.it("a package's content sum ignores its version but not its files", function()
    local pkg = t.fresh_import()("pkg")
    local files = {
      ["blockos/bin/music.lua"] = "print(1)",
      ["blockos/lib/music.lua"] = "return {}",
    }
    local a = pkg.content_sum({ name = "music", version = "0.3.0", optional = true }, files)
    local b = pkg.content_sum({ name = "music", version = "0.5.0", optional = true }, files)
    t.eq(a, b, "only the version differs")
    files["blockos/bin/music.lua"] = "print(2)"
    t.ok(pkg.content_sum({ name = "music", version = "0.5.0", optional = true }, files) ~= a,
      "a changed file changes the sum")
    local plain = pkg.content_sum({ name = "music", optional = false }, { ["x"] = "1" })
    local optional = pkg.content_sum({ name = "music", optional = true }, { ["x"] = "1" })
    t.ok(plain ~= optional, "manifest fields count")
  end)

  t.it("an update only lists packages whose version changed", function()
    local pkg = t.fresh_import()("pkg")
    local index = { version = "0.5.0", packages = {
      core = { version = "0.5.0" }, net = { version = "0.4.0" }, music = { version = "0.3.0" },
      domain = { version = "0.5.0" },
    } }
    local installed = {
      core = { version = "0.4.0" },
      net = { version = "0.4.0" },
      music = { version = "0.3.0" },
    }
    local changes = pkg.changes(index, { "core", "domain", "music", "net" }, installed)
    t.eq(#changes, 2)
    t.eq(changes[1].name, "core")
    t.eq(changes[1].from, "0.4.0")
    t.eq(changes[1].to, "0.5.0")
    t.eq(changes[2].name, "domain")
    t.eq(changes[2].from, nil, "new packages have no old version")
  end)
end
