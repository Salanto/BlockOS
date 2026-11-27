--- Computer roles on the computer's side: apply what the directory says this computer
-- should have (settings, packages) and keep its packages up to date.
--
-- Roles describe a desired state and the computer converges on it, like Puppet or
-- Terraform. Normally only by adding and updating: packages are never removed, so a
-- mistake in a role cannot wipe anything. A role marked "keep only these" (prune) also
-- removes every optional package none of the computer's roles list, except what must
-- stay (KEEP: core, net, the domain package) and the dependencies of what is kept.
-- `domain update --plan` and dsa's computer info show the plan before it is applied.
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

--- Optional packages a prune never removes: without `domain` the computer would leave the
-- domain and no role could reach it again.
computer_config.KEEP = { "domain" }

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

--- The packages a prune keeps: the base set, KEEP, what the roles ask for, and every
-- dependency of those (from the index and from what is installed, so nothing either
-- version needs is removed).
-- @tparam table index
-- @tparam {string...} wanted
-- @tparam table installed
-- @treturn table [name] = true
function computer_config.keep_set(index, wanted, installed)
  local keep = {}
  local function visit(name)
    if keep[name] then
      return
    end
    keep[name] = true
    for _, entry in ipairs({ index.packages[name] or {}, installed[name] or {} }) do
      for dependency in pairs(entry.depends or {}) do
        visit(dependency)
      end
    end
  end
  for _, packages in ipairs({ index.packages, installed }) do
    for name, entry in pairs(packages) do
      if not entry.optional then
        visit(name)
      end
    end
  end
  for _, name in ipairs(computer_config.KEEP) do
    visit(name)
  end
  for _, name in ipairs(wanted or {}) do
    visit(name)
  end
  return keep
end

--- What to install, update and (with prune) remove.
-- @tparam table index The source's index.
-- @tparam {string...} wanted Packages the computer's roles ask for.
-- @tparam[opt] table installed Default: installed packages.
-- @tparam[opt] boolean prune Remove optional packages the roles do not list.
-- @treturn table { changes = { name, from, to }..., missing = { names not in the source },
--   removals = { names } }
function computer_config.plan(index, wanted, installed, prune)
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
  local removals, removed = {}, {}
  if prune then
    local keep = computer_config.keep_set(index, wanted, installed)
    for name, entry in pairs(installed) do
      if entry.optional and not keep[name] then
        removals[#removals + 1] = name
        removed[name] = true
      end
    end
    table.sort(removals)
  end
  -- installed packages, the base set, what the roles ask for, and their dependencies,
  -- without the ones being removed (no point updating them first)
  local names = {}
  for _, name in ipairs(pkg.select(index, present, installed) or {}) do
    if not removed[name] then
      names[#names + 1] = name
    end
  end
  return { changes = pkg.changes(index, names, installed), missing = missing,
    removals = removals }
end

-- The directory's config and the source's index.
local function desired_and_index()
  local desired, err = computer_config.env.fetch_config()
  if not desired then
    return nil, "cannot get this computer's roles: " .. tostring(err)
  end
  local source = computer_config.source()
  local index, index_error = source.index()
  if not index then
    return nil, "cannot read " .. source.describe() .. ": " .. tostring(index_error)
  end
  return desired, index, source
end

--- What applying the roles would do now, without changing anything (`domain update
-- --plan`, dsa's computer info).
-- @treturn[1] table { roles, prune, settings = { keys that would change }, changes,
--   removals, missing }
-- @treturn[2] nil
-- @treturn[2] string error message
function computer_config.preview()
  local desired, index = desired_and_index()
  if not desired then
    return nil, index
  end
  local settings = {}
  for key, value in pairs(desired.settings or {}) do
    if type(key) == "string" and key:match("^blockos%.")
      and computer_config.env.get_setting(key) ~= value then
      settings[#settings + 1] = key
    end
  end
  table.sort(settings)
  local plan = computer_config.plan(index, desired.packages, nil, desired.prune)
  return {
    roles = desired.roles or {},
    prune = desired.prune == true,
    settings = settings,
    changes = plan.changes,
    removals = plan.removals,
    missing = plan.missing,
  }
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
-- @treturn[1] table { config, settings_changed, changes, missing, removals, packages
--   (fetched; nil if nothing to do) }
-- @treturn[2] nil
-- @treturn[2] string error message
function computer_config.check(progress)
  local pkg = import("pkg")
  local desired, index, source = desired_and_index()
  if not desired then
    return nil, index
  end
  local result = {
    config = desired,
    settings_changed = computer_config.apply_settings(desired.settings),
  }
  local plan = computer_config.plan(index, desired.packages, nil, desired.prune)
  result.changes, result.missing, result.removals = plan.changes, plan.missing, plan.removals
  if #plan.changes == 0 then
    -- Only removals: nothing to fetch, but something to apply.
    result.packages = #plan.removals > 0 and {} or nil
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

--- A preview as lines to show, like `terraform plan`: what would be installed, updated,
-- removed and set.
-- @tparam table preview From computer_config.preview.
-- @treturn {table...} { text, role } (role: a ui theme role)
function computer_config.plan_lines(preview)
  local lines = {}
  local function add(text, role)
    lines[#lines + 1] = { text = text, role = role }
  end
  for _, change in ipairs(preview.changes) do
    if change.from then
      add("~ " .. change.name .. " " .. change.from .. " > " .. change.to, "warn")
    else
      add("+ " .. change.name .. " " .. change.to, "ok")
    end
  end
  for _, name in ipairs(preview.removals) do
    add("- " .. name, "error")
  end
  for _, key in ipairs(preview.settings) do
    add("= " .. key, "text")
  end
  for _, name in ipairs(preview.missing) do
    add("? " .. name .. " (not in the package source)", "dim")
  end
  if #lines == 0 then
    add("Up to date: nothing to change.", "ok")
  end
  if not preview.prune then
    add("Packages its roles do not list are kept (no role says keep only).", "dim")
  end
  return lines
end

--- Describe a change list for logs and notices: "logistics 0.4.0>0.5.0, music new,
-- paint removed".
-- @tparam {table...} changes
-- @tparam[opt] {string...} removals
-- @treturn string
function computer_config.describe(changes, removals)
  local parts = {}
  for _, change in ipairs(changes) do
    local what = change.from and (change.from .. ">" .. change.to) or "new"
    parts[#parts + 1] = change.name .. " " .. what
  end
  for _, name in ipairs(removals or {}) do
    parts[#parts + 1] = name .. " removed"
  end
  return table.concat(parts, ", ")
end

return computer_config
