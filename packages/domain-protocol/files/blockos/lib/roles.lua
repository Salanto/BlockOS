--- Module roles: every module works standalone and open; in a domain it goes into
-- managed mode, where access comes from roles kept in the directory.
--
-- Modes of a package (decided by the directory, so every computer agrees):
--   standalone    the computer is not in a domain: open
--   unconfigured  in a domain, but no domain admin ran `domain setup <package>`: still
--                 open, and the login screen shows a notice
--   managed       the package's roles exist in the directory: access needs the role
--
-- Packages declare their roles in their manifest:
--   roles = { { name = "turtle-drivers", default = "everyone", description = "..." } }
-- `default` is "everyone" (every domain user, now and later), "installer" (the domain admin
-- running the setup) or "nobody". A role named `<module>-admins` manages the module's other
-- roles: its members may change who is in them, without a domain admin.
-- @module roles

local rpc = import("rpc")

local roles = {}

roles.CACHE_SECONDS = 60
roles.NOT_SET_UP = "no such group"

--- Access to the domain and the package database (tests replace these).
roles.env = {
  is_joined = function() return import("domain").is_joined() end,
  group_get = function(name) return import("domain").group_get(name) end,
  require_user = function(ctx, groups) return rpc.require_user(ctx, groups) end,
  installed = function() return import("pkg").installed() end,
  clock = function() return os.clock() end,
}

local cache = {}

--- Forget cached role info (after a setup, or in tests).
function roles.clear_cache()
  cache = {}
end

--- The roles a package declares in its manifest.
-- @tparam string package
-- @treturn {table...} { name, default, description }
function roles.declared(package)
  local _, entry = roles.package_with_roles(package)
  return entry and entry.roles or {}
end

--- The installed package that declares a family's roles. Packages are split by kind,
-- and a family's roles live on its protocol package (every computer of the family
-- has it), so `logistics`, `turtle-remote` and `logistics-protocol` all find them.
-- @tparam string name A package or family name.
-- @treturn[1] string The package's name.
-- @treturn[1] table Its packages.db entry.
-- @treturn[2] nil
function roles.package_with_roles(name)
  local installed = roles.env.installed()
  local family = tostring(name):match("^(.-)%-[%a]+$")
  local candidates = { name, name .. "-protocol", family and (family .. "-protocol") }
  for _, candidate in ipairs(candidates) do
    local entry = installed[candidate]
    if entry and entry.roles and #entry.roles > 0 then
      return candidate, entry
    end
  end
  return nil
end

--- How people call a package's family: logistics-protocol -> logistics.
-- @tparam string name
-- @treturn string
function roles.family(name)
  return (tostring(name):gsub("%-protocol$", ""))
end

--- Role info from the directory, cached for a minute.
-- @tparam string name
-- @treturn[1] table { name, everyone, managed_by }
-- @treturn[2] nil
-- @treturn[2] string error message (roles.NOT_SET_UP when the role does not exist)
function roles.info(name)
  local now = roles.env.clock()
  local hit = cache[name]
  if hit and now - hit.time < roles.CACHE_SECONDS then
    return hit.info, hit.err
  end
  local info, err = roles.env.group_get(name)
  if not info and err ~= roles.NOT_SET_UP and hit then
    -- The controller did not answer: keep using what we knew (degraded mode).
    hit.time = now
    return hit.info, hit.err
  end
  cache[name] = { info = info, err = err, time = now }
  return info, err
end

--- @tparam string package
-- @treturn string "standalone", "unconfigured" or "managed"
function roles.mode(package)
  if not roles.env.is_joined() then
    return "standalone"
  end
  local declared = roles.declared(package)
  if #declared == 0 then
    return "standalone"
  end
  local info, err = roles.info(declared[1].name)
  if not info and err == roles.NOT_SET_UP then
    return "unconfigured"
  end
  return "managed"
end

--- May this request use what the role guards? Open unless the module is managed.
-- @tparam table ctx An rpc request context ({ token?, computer_token?, local_admin? }).
-- @tparam string role
-- @treturn[1] true
-- @treturn[2] nil
-- @treturn[2] string error message
function roles.allows(ctx, role)
  if not roles.env.is_joined() then
    return true
  end
  local info, err = roles.info(role)
  if not info and err == roles.NOT_SET_UP then
    return true -- joined, but nobody set the module up yet: still open
  end
  if ctx.local_admin then
    return true -- at this computer's own keyboard: a broken role can always be fixed
  end
  if ctx.token then
    local user, user_err = roles.env.require_user(ctx, { role })
    if user then
      return true
    end
    -- The controller is down: a role open to everyone stays open (degraded mode);
    -- restricted ones stay closed until it is back.
    if user_err == rpc.UNREACHABLE and info and info.everyone then
      return true
    end
    return nil, user_err
  end
  -- No user (e.g. a turtle's service): allowed where the role includes everyone.
  if info and info.everyone then
    return true
  end
  return nil, rpc.LOGIN_REQUIRED
end

--- Packages that declare roles but are not set up for the domain yet.
-- @treturn {string...}
--- Allowed by a role, or (with admins = true) as a domain admin.
-- @tparam table ctx Request context.
-- @tparam string role
-- @tparam[opt] table options { admins = true }
-- @treturn[1] true
-- @treturn[2] nil
-- @treturn[2] string error message
function roles.require(ctx, role, options)
  local ok, err = roles.allows(ctx, role)
  if ok then
    return true
  end
  if options and options.admins and ctx.token
    and roles.env.require_user(ctx, { rpc.DOMAIN_ADMINS }) then
    return true
  end
  return nil, err
end

function roles.pending()
  local list = {}
  if not roles.env.is_joined() then
    return list
  end
  for name, entry in pairs(roles.env.installed()) do
    if entry.roles and #entry.roles > 0 and roles.mode(name) == "unconfigured" then
      list[#list + 1] = roles.family(name)
    end
  end
  table.sort(list)
  return list
end

------------------------------------------------------------------------------
-- Guided setup
------------------------------------------------------------------------------

local function admin_role_of(declared)
  for _, role in ipairs(declared) do
    if role.name:match("%-admins$") then
      return role.name
    end
  end
  return nil
end

local function split_names(text)
  local names = {}
  for name in tostring(text):gmatch("[^,%s]+") do
    names[#names + 1] = name
  end
  return names
end

--- Work out what a setup will create.
-- @tparam {table...} declared The package's roles.
-- @tparam string admin_name The domain admin running the setup.
-- @tparam[opt] table answers [role name] = typed answer: "" or nil keeps the default,
--   "everyone" opens the role to everyone, otherwise a list of user names.
-- @treturn {table...} { name, description, everyone, members, managed_by }
function roles.plan(declared, admin_name, answers)
  answers = answers or {}
  local admin_role = admin_role_of(declared)
  local plan = {}
  for _, role in ipairs(declared) do
    local answer = answers[role.name]
    local entry = {
      name = role.name,
      description = role.description,
      everyone = false,
      members = {},
      -- the module's admin role manages itself and every other role of the module
      managed_by = admin_role,
    }
    if answer == nil or answer == "" then
      if role.default == "everyone" then
        entry.everyone = true
      elseif role.default == "installer" then
        entry.members = { admin_name }
      end
    elseif answer == "everyone" then
      entry.everyone = true
    else
      entry.members = split_names(answer)
    end
    plan[#plan + 1] = entry
  end
  return plan
end

--- Create the planned roles in the directory. Roles that already exist are kept.
-- @tparam {table...} plan From roles.plan.
-- @tparam function call function(op, args) -> result, err (as a domain admin)
-- @treturn {string...} What happened, one line per role.
function roles.apply(plan, call)
  local report = {}
  -- the admin role first: the others name it as their manager
  table.sort(plan, function(a, b)
    return (a.name == a.managed_by and 0 or 1) < (b.name == b.managed_by and 0 or 1)
  end)
  for _, entry in ipairs(plan) do
    local ok, err = call("group_add", {
      name = entry.name,
      everyone = entry.everyone or nil,
      managed_by = entry.managed_by,
    })
    if not ok and tostring(err) ~= "group already exists" then
      report[#report + 1] = entry.name .. ": " .. tostring(err)
    else
      for _, member in ipairs(entry.members) do
        local added, add_err = call("group_addmember", { group = entry.name, user = member })
        if not added then
          report[#report + 1] = entry.name .. ": " .. member .. ": " .. tostring(add_err)
        end
      end
      local who = entry.everyone and "everyone" or table.concat(entry.members, ", ")
      report[#report + 1] = entry.name .. ": " .. (who ~= "" and who or "nobody yet") ..
        (ok and "" or " (already existed)")
    end
  end
  roles.clear_cache()
  return report
end

--- Create one more role of a module after its setup, e.g. a role per storage node. The
-- caller must be a domain admin or in the module's admin role.
-- @tparam string name e.g. "logistics-node-ores"
-- @tparam string admin_role e.g. "logistics-admins"
-- @tparam[opt] boolean everyone Start open to everyone (the friendly default).
-- @treturn[1] true
-- @treturn[2] nil
-- @treturn[2] string error message
function roles.create(name, admin_role, everyone)
  local result, err = import("domain").call("group_add", {
    name = name,
    everyone = everyone ~= false or nil,
    managed_by = admin_role,
  })
  roles.clear_cache()
  if not result and tostring(err) ~= "group already exists" then
    return nil, err
  end
  return true
end

return roles
