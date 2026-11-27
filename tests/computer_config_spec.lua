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
end
