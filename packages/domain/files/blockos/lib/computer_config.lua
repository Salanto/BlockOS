--- Computer roles on the computer's side: apply what the directory says this computer
-- should have (settings, packages) and keep its packages up to date.
--
-- The plan is pure (index, desired packages, installed) so it is tested without a
-- network; the computer-config service fetches, applies and reboots.
-- @module computer_config

local config = import("config")

local computer_config = {}

--- Queue this event to check roles and updates now and apply them even when someone is
-- logged in (`domain update`, remote admin).
computer_config.UPDATE_NOW_EVENT = "blockos_update_now"

config.define("blockos.domain.auto_update", {
  description = "Install and update packages by themselves (from the computer's roles).",
  default = true,
  type = "boolean",
})
config.define("blockos.domain.update_interval", {
  description = "Seconds between checks for package updates.",
  default = 1800,
  type = "number",
})

--- Access to the outside world (tests replace these).
computer_config.env = {
  fetch_config = function() return import("domain").computer_config() end,
  get_setting = function(key) return config.get(key) end,
  set_setting = function(key, value) config.set(key, value) end,
  installed = function() return import("pkg").installed() end,
}

--- Apply the role settings that differ from the current ones.
-- @tparam table settings [blockos.* key] = value
-- @treturn {string...} The keys that changed.
function computer_config.apply_settings(settings)
  local changed = {}
  for key, value in pairs(settings or {}) do
    local is_ours = type(key) == "string" and key:match("^blockos%.") ~= nil
    if is_ours and computer_config.env.get_setting(key) ~= value then
      computer_config.env.set_setting(key, value)
      changed[#changed + 1] = key
    end
  end
  table.sort(changed)
  return changed
end

--- What to install or update.
-- @tparam table index The source's index.
-- @tparam {string...} wanted Packages the computer's roles ask for.
-- @tparam[opt] table installed Default: installed packages.
-- @treturn table { changes = { name, from, to }..., missing = { names not in the source } }
function computer_config.plan(index, wanted, installed)
  local pkg = import("pkg")
  installed = installed or computer_config.env.installed()
  local present, missing = {}, {}
  for _, name in ipairs(wanted or {}) do
    if index.packages[name] then
      present[#present + 1] = name
    else
      missing[#missing + 1] = name
    end
  end
  -- installed packages, the base set, what the roles ask for, and their dependencies
  local names = pkg.select(index, present, installed)
  return { changes = pkg.changes(index, names or {}, installed), missing = missing }
end

--- Where packages come from: the package server when one is found, else GitHub
-- (the same choice `pkg` makes without flags).
function computer_config.source()
  local pkg = import("pkg")
  local found, pkg_remote = pcall(import, "pkg_remote")
  if found then
    local id, label = pkg_remote.find_server()
    if id then
      return pkg_remote.source(id, label)
    end
  end
  return pkg.github_source()
end

--- Fetch this computer's config, apply its settings, and fetch the packages to change.
-- @tparam[opt] function progress
-- @treturn[1] table { config, settings_changed, changes, missing, packages (fetched; nil if
--   nothing to do) }
-- @treturn[2] nil
-- @treturn[2] string error message
function computer_config.check(progress)
  local pkg = import("pkg")
  local desired, err = computer_config.env.fetch_config()
  if not desired then
    return nil, "cannot get this computer's roles: " .. tostring(err)
  end
  local result = {
    config = desired,
    settings_changed = computer_config.apply_settings(desired.settings),
  }
  local source = computer_config.source()
  local index, index_error = source.index()
  if not index then
    return nil, "cannot read " .. source.describe() .. ": " .. tostring(index_error)
  end
  local plan = computer_config.plan(index, desired.packages)
  result.changes, result.missing = plan.changes, plan.missing
  if #plan.changes == 0 then
    return result
  end
  local names = {}
  for _, change in ipairs(plan.changes) do
    names[#names + 1] = change.name
  end
  local fetched, packages = pkg.fetch(source, progress, names)
  if not fetched then
    return nil, packages
  end
  result.packages = packages
  return result
end

--- Describe a change list for logs and notices: "logistics 0.4.0>0.5.0, music new".
function computer_config.describe(changes)
  local parts = {}
  for _, change in ipairs(changes) do
    local what = change.from and (change.from .. ">" .. change.to) or "new"
    parts[#parts + 1] = change.name .. " " .. what
  end
  return table.concat(parts, ", ")
end

return computer_config
