-- Computer roles on the computer: settings it applies and the packages it installs/updates.
return function(t)
  local INDEX = { version = "0.6.0", packages = {
    core = { version = "0.6.0" },
    net = { version = "0.4.0", depends = { core = ">=0.1.0-0" } },
    logistics = { version = "0.6.0", optional = true, depends = { net = ">=0.1.0-0" } },
    ["logistics-node"] = {
      version = "0.6.0", optional = true, depends = { logistics = ">=0.1.0-0" },
    },
    music = { version = "0.3.0", optional = true },
  } }

  local function new_config(settings)
    local computer_config = t.fresh_import()("computer_config")
    local store = settings or {}
    computer_config.env.get_setting = function(key) return store[key] end
    computer_config.env.set_setting = function(key, value) store[key] = value end
    return computer_config, store
  end

  t.it("role settings are applied only where they differ, and only blockos.* keys", function()
    local computer_config, store = new_config({ ["blockos.autologin"] = "farmer" })
    local changed = computer_config.apply_settings({
      ["blockos.autologin"] = "farmer",
      ["blockos.logistics.board"] = "monitor_0",
      ["shell.allow_disk_startup"] = false,
    })
    t.eq(#changed, 1)
    t.eq(changed[1], "blockos.logistics.board")
    t.eq(store["blockos.logistics.board"], "monitor_0")
    t.eq(store["shell.allow_disk_startup"], nil, "other settings are never touched")
  end)

  t.it("a new role installs its packages with their dependencies", function()
    local computer_config = new_config()
    local installed = { core = { version = "0.6.0" }, net = { version = "0.4.0" } }
    local plan = computer_config.plan(INDEX, { "logistics-node" }, installed)
    local names = {}
    for _, change in ipairs(plan.changes) do
      names[#names + 1] = change.name .. ":" .. tostring(change.from)
    end
    t.eq(table.concat(names, ","), "logistics:nil,logistics-node:nil")
    t.eq(#plan.missing, 0)
  end)

  t.it("installed packages update; unchanged ones and unknown names don't download", function()
    local computer_config = new_config()
    local installed = {
      core = { version = "0.5.0" }, net = { version = "0.4.0" }, music = { version = "0.3.0" },
    }
    local plan = computer_config.plan(INDEX, { "music", "teleporter" }, installed)
    t.eq(#plan.changes, 1)
    t.eq(plan.changes[1].name, "core")
    t.eq(plan.changes[1].to, "0.6.0")
    t.eq(plan.missing[1], "teleporter", "a package the source doesn't have is reported")
    t.eq(computer_config.describe(plan.changes), "core 0.5.0>0.6.0")
  end)

  -- A computer with a role for logistics-node that also has music, a leftover paint app,
  -- and the domain package.
  local function cluttered()
    return {
      core = { version = "0.6.0" },
      net = { version = "0.4.0", depends = { core = ">=0.1.0-0" } },
      logistics = { version = "0.6.0", optional = true, depends = { net = ">=0.1.0-0" } },
      ["logistics-node"] = { version = "0.6.0", optional = true,
        depends = { logistics = ">=0.1.0-0" } },
      music = { version = "0.3.0", optional = true },
      paint = { version = "0.1.0", optional = true, depends = { ["paint-lib"] = "*" } },
      ["paint-lib"] = { version = "0.1.0", optional = true },
      domain = { version = "0.6.0", optional = true, depends = { ["domain-protocol"] = "*" } },
      ["domain-protocol"] = { version = "0.6.0", optional = true },
    }
  end

  t.it("without keep-only nothing is removed", function()
    local computer_config = new_config()
    local plan = computer_config.plan(INDEX, { "logistics-node" }, cluttered())
    t.eq(#plan.removals, 0)
  end)

  t.it("keep-only removes what no role lists, never the base, domain or dependencies", function()
    local computer_config = new_config()
    local plan = computer_config.plan(INDEX, { "logistics-node" }, cluttered(), true)
    t.eq(table.concat(plan.removals, ","), "music,paint,paint-lib",
      "logistics stays (a dependency); domain and domain-protocol stay (KEEP)")
    t.eq(computer_config.describe({}, plan.removals), "music removed, paint removed, "
      .. "paint-lib removed")
    for _, change in ipairs(plan.changes) do
      t.ok(change.name ~= "music", "a package being removed is not updated first")
    end
    local kept = computer_config.plan(INDEX, { "logistics-node", "paint" }, cluttered(), true)
    t.eq(table.concat(kept.removals, ","), "music",
      "a listed package keeps its dependencies, even ones only the installed copy names")
  end)

  t.it("the plan shows installs, updates, removals and settings", function()
    local computer_config = new_config()
    local lines = computer_config.plan_lines({
      prune = true,
      changes = { { name = "music", to = "0.3.0" }, { name = "core", from = "0.5.0",
        to = "0.6.0" } },
      removals = { "paint" },
      settings = { "blockos.autologin" },
      missing = { "teleporter" },
    })
    local texts = {}
    for _, line in ipairs(lines) do
      texts[#texts + 1] = line.text
    end
    t.eq(table.concat(texts, "|"), "+ music 0.3.0|~ core 0.5.0 > 0.6.0|- paint|"
      .. "= blockos.autologin|? teleporter (not in the package source)")
    local calm = computer_config.plan_lines({ changes = {}, removals = {}, settings = {},
      missing = {} })
    t.eq(calm[1].text, "Up to date: nothing to change.")
    t.ok(calm[2].text:find("kept"), "says that other packages stay")
  end)

  t.it("the controller keeps a role's keep-only flag and merges it per computer", function()
    local import = t.fresh_import()
    local dir = assert(import("directory").create("home", "admin", "secret"))
    dir:join("pc1", 7)
    t.ok(dir:set_computer_role("node", { "logistics-node" }, nil, true))
    t.ok(dir:set_computer_role("tunes", { "music" }))
    t.ok(dir:assign_computer_roles("pc1", { "tunes" }))
    t.eq(dir:computer_config("pc1").prune, nil, "no role says keep only")
    t.ok(dir:assign_computer_roles("pc1", { "tunes", "node" }))
    t.eq(dir:computer_config("pc1").prune, true, "one role is enough")
    t.ok(dir:set_computer_role("node", { "logistics-node", "music" }))
    t.eq(dir:list_computer_roles()[1].prune, true,
      "changing packages without the flag (older tools) keeps it")
    t.ok(dir:set_computer_role("node", { "logistics-node" }, nil, false))
    t.eq(dir:computer_config("pc1").prune, nil, "switched off")
  end)
end
