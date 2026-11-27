--- The domain directory: users, groups, computers, host and service records,
-- and user sessions. Loosely modelled on Active Directory (see CLAUDE.md).
--
-- This module is pure logic over a data table, so it can be unit-tested; the
-- domain-controller service saves the data and serves it over rpc.
--
-- Data layout (saved to /etc/blockos/directory):
--   domain    "home"
--   users     [name] = { salt, hash, is_enabled }
--   groups    [name] = { members = { [user] = true }, everyone?, managed_by? }
--             (everyone: every domain user is a member; managed_by: a group whose
--             members may manage this one; module roles use both, see roles.lua)
--   computers [hostname] = { id, token, last_seen_day, roles? = { computer role names } }
--   computer_roles [name] = { packages = { names }, settings = { [blockos.* key] = value } }
--             (what a computer should have installed and set; computers apply it themselves)
--   services  [type] = { host, protocol }
-- User sessions are saved separately (/etc/blockos/sessions), so logins survive
-- a controller restart; their times are real seconds (os.epoch). What computers
-- report about themselves (info, kind, version, exact last-seen time) stays in
-- memory, which keeps the saved files small.
-- @module directory

local auth = import("auth")

local Directory = {}
Directory.__index = Directory

local directory = {}

directory.ADMINS = "domain-admins"
directory.USERS = "domain-users"
directory.BUILTIN_GROUPS = { directory.ADMINS, directory.USERS }

--- How long a login lasts, in real seconds. Friends only: long and forgiving.
directory.SESSION_SECONDS = 24 * 60 * 60

--- Largest status report (serialised info) a computer may send.
directory.MAX_INFO_BYTES = 1024

--- Largest computer role (serialised), and how many roles a computer may have.
directory.MAX_ROLE_BYTES = 1024
directory.MAX_ROLES_PER_COMPUTER = 8

--- Largest roaming profile (serialised) and how many apps it may list.
directory.MAX_PROFILE_BYTES = 1024
directory.MAX_PROFILE_APPS = 8

--- Computers not seen for this many days are marked stale (never deleted
-- automatically: a turtle may be away for a long time).
directory.STALE_DAYS = 7

local TOKEN_LENGTH = 32

local function new_token()
  local hex = {}
  for i = 1, TOKEN_LENGTH do
    hex[i] = string.format("%x", math.random(0, 15))
  end
  return table.concat(hex)
end

local function is_valid_name(name)
  return type(name) == "string" and #name >= 1 and #name <= 32 and name:match("^[%w_%-]+$") ~= nil
end

--- Create a new, empty domain.
-- @tparam string domain_name
-- @tparam string admin_name First domain admin.
-- @tparam string admin_password
-- @treturn[1] Directory
-- @treturn[2] nil
-- @treturn[2] string error message
function directory.create(domain_name, admin_name, admin_password)
  if not is_valid_name(domain_name) or domain_name ~= domain_name:lower() then
    return nil, "invalid domain name (lower case letters, digits, - and _)"
  end
  local self = directory.load({ domain = domain_name })
  local ok, err = self:add_user(admin_name, admin_password)
  if not ok then
    return nil, err
  end
  self:add_member(directory.ADMINS, admin_name)
  return self
end

--- Wrap saved data (fills in anything missing).
-- @tparam table data
-- @tparam[opt] table sessions Saved sessions (see saved_sessions).
-- @treturn Directory
function directory.load(data, sessions)
  local self = setmetatable({}, Directory)
  self.data = data
  data.users = data.users or {}
  data.groups = data.groups or {}
  data.computers = data.computers or {}
  data.services = data.services or {}
  data.computer_roles = data.computer_roles or {}
  data.profiles = data.profiles or {}
  for _, group in ipairs(directory.BUILTIN_GROUPS) do
    data.groups[group] = data.groups[group] or { members = {} }
  end
  -- Older versions saved reported status too; it now lives in memory only.
  local VOLATILE_FIELDS = { "info", "kind", "version", "last_seen" }
  for _, computer in pairs(data.computers) do
    for _, field in ipairs(VOLATILE_FIELDS) do
      computer[field] = nil
    end
  end
  self.sessions = sessions or {}
  self.status = {}
  return self
end

--- @treturn string The domain name.
function Directory:name()
  return self.data.domain
end

------------------------------------------------------------------------------
-- Users
------------------------------------------------------------------------------

function Directory:add_user(name, password)
  if not is_valid_name(name) then
    return nil, "invalid user name"
  end
  if self.data.users[name] then
    return nil, "user already exists"
  end
  if type(password) ~= "string" or password == "" then
    return nil, "password must not be empty"
  end
  local salt = auth.new_salt()
  self.data.users[name] = {
    salt = salt,
    hash = auth.hash_password(salt, password),
    is_enabled = true,
  }
  return true
end

function Directory:remove_user(name)
  if not self.data.users[name] then
    return nil, "no such user"
  end
  if self:is_member(directory.ADMINS, name) and self:count_members(directory.ADMINS) == 1 then
    return nil, "cannot remove the last domain admin"
  end
  self.data.users[name] = nil
  self.data.profiles[name] = nil
  for _, group in pairs(self.data.groups) do
    group.members[name] = nil
  end
  self:end_sessions_of(name)
  return true
end

------------------------------------------------------------------------------
-- Routing (for a mail server: who a message reaches, and where they are)
------------------------------------------------------------------------------

-- Who a message to `to` reaches: one user, or every member of a group.
local function recipients_of(self, to)
  if self.data.users[to] then
    return { to }
  end
  if not self.data.groups[to] then
    return nil, "no user or group called " .. tostring(to)
  end
  local names = {}
  for name in pairs(self.data.users) do
    if self:is_member(to, name) then
      names[#names + 1] = name
    end
  end
  table.sort(names)
  return names
end

--- The computers a user is logged in at right now (from their sessions).
-- @tparam string name
-- @tparam number now
-- @treturn {number...} computer IDs
function Directory:computers_of(name, now)
  local ids, seen = {}, {}
  for _, session in pairs(self.sessions) do
    if session.name == name and session.computer and session.expires > now
      and not seen[session.computer] then
      seen[session.computer] = true
      ids[#ids + 1] = session.computer
    end
  end
  return ids
end

--- Who a message to a user or group reaches, and the computers each is logged in at.
-- @tparam string to User or group.
-- @tparam number now
-- @treturn[1] {table...} { name, computers = { id... } }
-- @treturn[2] nil
-- @treturn[2] string error message
function Directory:route(to, now)
  local names, err = recipients_of(self, to)
  if not names then
    return nil, err
  end
  local route = {}
  for _, name in ipairs(names) do
    route[#route + 1] = { name = name, computers = self:computers_of(name, now) }
  end
  return route
end

------------------------------------------------------------------------------
-- Roaming profiles
------------------------------------------------------------------------------

local function check_profile(profile)
  if type(profile.apps) ~= "table" or #profile.apps > directory.MAX_PROFILE_APPS then
    return nil, "a profile lists at most " .. directory.MAX_PROFILE_APPS .. " apps"
  end
  for _, app in ipairs(profile.apps) do
    if type(app) ~= "string" or not app:match("^[%w_%-%.]+$") or #app > 32 then
      return nil, "invalid app name: " .. tostring(app)
    end
  end
  for key, value in pairs(profile.settings) do
    if type(key) ~= "string" or not key:match("^blockos%.") then
      return nil, "settings must be blockos.* keys: " .. tostring(key)
    end
    local kind = type(value)
    if kind ~= "string" and kind ~= "number" and kind ~= "boolean" then
      return nil, "setting " .. key .. " must be text, a number or true/false"
    end
  end
  if #textutils.serialise(profile, { compact = true }) > directory.MAX_PROFILE_BYTES then
    return nil, "profile too large (at most " .. directory.MAX_PROFILE_BYTES .. " bytes)"
  end
  return true
end

--- A user's roaming profile: the apps opened at login and settings that follow them.
-- @tparam string name
-- @treturn table { apps = {...}, settings = { [blockos.* key] = value } }
function Directory:get_profile(name)
  local profile = self.data.profiles[name] or {}
  return { apps = profile.apps or {}, settings = profile.settings or {} }
end

--- Replace parts of a user's roaming profile.
-- @tparam string name
-- @tparam table changes { apps?, settings? }
-- @treturn[1] table The new profile.
-- @treturn[2] nil
-- @treturn[2] string error message
function Directory:set_profile(name, changes)
  if not self.data.users[name] then
    return nil, "no such user"
  end
  local profile = self:get_profile(name)
  profile.apps = changes.apps or profile.apps
  profile.settings = changes.settings or profile.settings
  local ok, err = check_profile(profile)
  if not ok then
    return nil, err
  end
  local is_empty = #profile.apps == 0 and next(profile.settings) == nil
  self.data.profiles[name] = not is_empty and profile or nil
  return profile
end

function Directory:set_password(name, password)
  local user = self.data.users[name]
  if not user then
    return nil, "no such user"
  end
  if type(password) ~= "string" or password == "" then
    return nil, "password must not be empty"
  end
  user.salt = auth.new_salt()
  user.hash = auth.hash_password(user.salt, password)
  return true
end

function Directory:set_enabled(name, is_enabled)
  local user = self.data.users[name]
  if not user then
    return nil, "no such user"
  end
  user.is_enabled = is_enabled
  if not is_enabled then
    self:end_sessions_of(name)
  end
  return true
end

--- @treturn boolean True if the name and password match an enabled user.
function Directory:check_password(name, password)
  local user = self.data.users[name]
  if not user or not user.is_enabled or type(password) ~= "string" then
    return false
  end
  return auth.hash_password(user.salt, password) == user.hash
end

--- @treturn {table...} { name, is_enabled, groups } sorted by name.
function Directory:list_users()
  local users = {}
  for name, user in pairs(self.data.users) do
    users[#users + 1] = { name = name, is_enabled = user.is_enabled, groups = self:groups_of(name) }
  end
  table.sort(users, function(a, b) return a.name < b.name end)
  return users
end

------------------------------------------------------------------------------
-- Groups
------------------------------------------------------------------------------

local function is_builtin(group)
  for _, builtin in ipairs(directory.BUILTIN_GROUPS) do
    if builtin == group then
      return true
    end
  end
  return false
end

--- Create a group.
-- @tparam string name
-- @tparam[opt] table options { everyone = true (every domain user is a member, now and
--   later), managed_by = group whose members may manage this one (may be the group itself) }
-- @treturn[1] true
-- @treturn[2] nil
-- @treturn[2] string error message
function Directory:add_group(name, options)
  options = options or {}
  if not is_valid_name(name) then
    return nil, "invalid group name"
  end
  if self.data.groups[name] then
    return nil, "group already exists"
  end
  local manager = options.managed_by
  if manager ~= nil and manager ~= name and not self.data.groups[manager] then
    return nil, "no such group: " .. tostring(manager)
  end
  self.data.groups[name] = {
    members = {},
    everyone = options.everyone == true or nil,
    managed_by = manager,
  }
  return true
end

--- Make every domain user a member (now and later), or go back to listed members.
function Directory:set_everyone(name, everyone)
  local group = self.data.groups[name]
  if not group then
    return nil, "no such group"
  end
  if is_builtin(name) then
    return nil, "built-in groups cannot be changed this way"
  end
  group.everyone = everyone == true or nil
  return true
end

--- Set (or clear) the group whose members may manage this one.
function Directory:set_manager(name, manager)
  local group = self.data.groups[name]
  if not group then
    return nil, "no such group"
  end
  if manager ~= nil and manager ~= name and not self.data.groups[manager] then
    return nil, "no such group: " .. tostring(manager)
  end
  group.managed_by = manager
  return true
end

--- May this user change the group's members and its everyone flag? Domain admins may
-- change any group; members of the group's `managed_by` group may change that group.
-- @tparam string group
-- @tparam string user
-- @treturn boolean
function Directory:can_manage(group, user)
  if self:is_member(directory.ADMINS, user) then
    return true
  end
  local entry = self.data.groups[group]
  return entry ~= nil and entry.managed_by ~= nil and self:is_member(entry.managed_by, user)
end

--- May this user create a group with this name, managed by `manager`? Domain admins may
-- create any group. A module's admins (`<module>-admins`) may create further roles of their
-- module (`<module>-...`) managed by themselves, e.g. one per storage node.
-- @tparam string name
-- @tparam string|nil manager
-- @tparam string user
-- @treturn boolean
function Directory:can_create(name, manager, user)
  if self:is_member(directory.ADMINS, user) then
    return true
  end
  if type(manager) ~= "string" or not self:is_member(manager, user) then
    return false
  end
  local module = manager:match("^(.+)%-admins$")
  return module ~= nil and name:sub(1, #module + 1) == module .. "-"
end

--- What modules need to know about a role (no member list).
-- @tparam string name
-- @treturn table|nil { name, everyone, managed_by }
function Directory:group_info(name)
  local group = self.data.groups[name]
  if not group then
    return nil
  end
  local everyone = group.everyone == true or name == directory.USERS
  return { name = name, everyone = everyone, managed_by = group.managed_by }
end

function Directory:remove_group(name)
  if not self.data.groups[name] then
    return nil, "no such group"
  end
  if is_builtin(name) then
    return nil, "built-in groups cannot be removed"
  end
  self.data.groups[name] = nil
  return true
end

function Directory:add_member(group, user)
  if not self.data.groups[group] then
    return nil, "no such group"
  end
  if not self.data.users[user] then
    return nil, "no such user"
  end
  self.data.groups[group].members[user] = true
  return true
end

function Directory:remove_member(group, user)
  if not self.data.groups[group] then
    return nil, "no such group"
  end
  local is_last_admin = group == directory.ADMINS and self:is_member(group, user)
    and self:count_members(group) == 1
  if is_last_admin then
    return nil, "cannot remove the last domain admin"
  end
  self.data.groups[group].members[user] = nil
  return true
end

function Directory:is_member(group, user)
  if group == directory.USERS then
    return self.data.users[user] ~= nil
  end
  local entry = self.data.groups[group]
  if entry == nil then
    return false
  end
  -- "everyone" groups include every domain user, also ones added later.
  if entry.everyone and self.data.users[user] ~= nil then
    return true
  end
  return entry.members[user] == true
end

function Directory:count_members(group)
  local count = 0
  for _ in pairs(self.data.groups[group].members) do
    count = count + 1
  end
  return count
end

--- @treturn {string...} Groups of a user, sorted (always includes domain-users).
function Directory:groups_of(user)
  local groups = {}
  for name in pairs(self.data.groups) do
    if self:is_member(name, user) then
      groups[#groups + 1] = name
    end
  end
  table.sort(groups)
  return groups
end

--- @treturn {table...} { name, members = {...}, everyone, managed_by, is_builtin } sorted by name.
function Directory:list_groups()
  local groups = {}
  for name, group in pairs(self.data.groups) do
    local members = {}
    for member in pairs(group.members) do
      members[#members + 1] = member
    end
    table.sort(members)
    groups[#groups + 1] = {
      name = name,
      members = members,
      everyone = group.everyone == true or name == directory.USERS,
      managed_by = group.managed_by,
      is_builtin = is_builtin(name),
    }
  end
  table.sort(groups, function(a, b) return a.name < b.name end)
  return groups
end

------------------------------------------------------------------------------
-- Computers and host records
------------------------------------------------------------------------------

--- May this user join computers to the domain? Any domain user may: we only
-- play with friends, so joining is not something to guard.
function Directory:can_join(name, password)
  return self:check_password(name, password)
end

--- Create (or replace) a computer account. Returns its long-lived token.
-- @tparam string hostname
-- @tparam number id Computer ID.
-- @treturn[1] string The computer token.
-- @treturn[2] nil
-- @treturn[2] string error message
function Directory:join(hostname, id)
  if not is_valid_name(hostname) then
    return nil, "invalid hostname"
  end
  local token = new_token()
  self.data.computers[hostname] = { id = id, token = token }
  self.status[hostname] = nil
  return token
end

--- @tparam string token
-- @treturn string|nil Hostname of the computer account with this token.
function Directory:computer_by_token(token)
  if type(token) ~= "string" then
    return nil
  end
  for hostname, computer in pairs(self.data.computers) do
    if computer.token == token then
      return hostname
    end
  end
  return nil
end

function Directory:remove_computer(hostname)
  if not self.data.computers[hostname] then
    return nil, "no such computer"
  end
  self.data.computers[hostname] = nil
  self.status[hostname] = nil
  for service_type, service in pairs(self.data.services) do
    if service.host == hostname then
      self.data.services[service_type] = nil
    end
  end
  return true
end

--- A computer reports its status. It may only change its own record; a rename
-- moves the record, and the service records pointing at it, to the new
-- hostname if that name is free.
--
-- Only the account (ID, token) and the day it was last seen are saved; the
-- reported info and the exact time stay in memory, so reports rarely cause a
-- disk write.
-- @tparam string token The computer's token.
-- @tparam table report { hostname, id, info, kind, version }
-- @tparam number now Seconds.
-- @tparam number today Day number (os.day("utc")).
-- @treturn[1] string The hostname now on record.
-- @treturn[1] boolean True if something that is saved changed.
-- @treturn[2] nil
-- @treturn[2] string error message
function Directory:update_host(token, report, now, today)
  local current = self:computer_by_token(token)
  if not current then
    return nil, "unknown computer"
  end
  local info = type(report.info) == "table" and report.info or {}
  if #textutils.serialise(info, { compact = true }) > directory.MAX_INFO_BYTES then
    return nil, "status report too large (at most " .. directory.MAX_INFO_BYTES .. " bytes of info)"
  end

  local computer = self.data.computers[current]
  local needs_save = false
  local wanted = report.hostname
  if is_valid_name(wanted) and wanted ~= current and not self.data.computers[wanted] then
    self.data.computers[wanted] = computer
    self.data.computers[current] = nil
    self.status[current] = nil
    -- Service records name a host, so they would point at nothing after the
    -- rename (e.g. "stock" or "pkg" could no longer be found).
    for _, service in pairs(self.data.services) do
      if service.host == current then
        service.host = wanted
      end
    end
    current = wanted
    needs_save = true
  end
  if report.id and report.id ~= computer.id then
    computer.id = report.id
    needs_save = true
  end
  if computer.last_seen_day ~= today then
    computer.last_seen_day = today
    needs_save = true
  end

  self.status[current] = {
    info = info,
    kind = type(report.kind) == "string" and report.kind or nil,
    version = type(report.version) == "string" and report.version or nil,
    last_seen = now,
  }
  return current, needs_save
end

--- @tparam string hostname Short hostname.
-- @treturn number|nil Computer ID.
function Directory:resolve(hostname)
  local computer = self.data.computers[hostname]
  return computer and computer.id
end

--- @tparam number now Seconds.
-- @tparam number today Day number.
-- @treturn {table...} { hostname, id, kind, version, info, age, days_unseen, is_stale }
--   sorted by hostname. `age` is nil until the computer reports after a
--   controller restart; `days_unseen` survives restarts.
function Directory:list_hosts(now, today)
  local hosts = {}
  for hostname, computer in pairs(self.data.computers) do
    local status = self.status[hostname] or {}
    local days_unseen = computer.last_seen_day and today and (today - computer.last_seen_day)
    hosts[#hosts + 1] = {
      hostname = hostname,
      id = computer.id,
      kind = status.kind or "?",
      version = status.version or "?",
      info = status.info or {},
      age = status.last_seen and (now - status.last_seen) or nil,
      days_unseen = days_unseen,
      is_stale = days_unseen ~= nil and days_unseen >= directory.STALE_DAYS,
      roles = computer.roles or {},
    }
  end
  table.sort(hosts, function(a, b) return a.hostname < b.hostname end)
  return hosts
end

------------------------------------------------------------------------------
-- Computer roles: what computers should have installed and set
------------------------------------------------------------------------------

local function check_role(role)
  if type(role.packages) ~= "table" then
    return nil, "a computer role needs a package list"
  end
  for _, name in ipairs(role.packages) do
    if not is_valid_name(name) then
      return nil, "invalid package name: " .. tostring(name)
    end
  end
  for key, value in pairs(role.settings or {}) do
    if type(key) ~= "string" or not key:match("^blockos%.") then
      return nil, "settings must be blockos.* keys: " .. tostring(key)
    end
    local kind = type(value)
    if kind ~= "string" and kind ~= "number" and kind ~= "boolean" then
      return nil, "setting " .. key .. " must be text, a number or true/false"
    end
  end
  if #textutils.serialise(role, { compact = true }) > directory.MAX_ROLE_BYTES then
    return nil, "computer role too large (at most " .. directory.MAX_ROLE_BYTES .. " bytes)"
  end
  return true
end

--- Create or replace a computer role.
-- @tparam string name e.g. "logistics-node"
-- @tparam {string...} packages Packages computers with this role should have.
-- @tparam[opt] table settings [blockos.* key] = value, applied on those computers.
-- @treturn[1] true
-- @treturn[2] nil
-- @treturn[2] string error message
function Directory:set_computer_role(name, packages, settings)
  if not is_valid_name(name) then
    return nil, "invalid computer role name"
  end
  local role = { packages = packages, settings = settings or {} }
  local ok, err = check_role(role)
  if not ok then
    return nil, err
  end
  table.sort(role.packages)
  self.data.computer_roles[name] = role
  return true
end

--- Remove a computer role (and take it off every computer).
function Directory:remove_computer_role(name)
  if not self.data.computer_roles[name] then
    return nil, "no such computer role"
  end
  self.data.computer_roles[name] = nil
  for _, computer in pairs(self.data.computers) do
    if computer.roles then
      local kept = {}
      for _, role in ipairs(computer.roles) do
        if role ~= name then
          kept[#kept + 1] = role
        end
      end
      computer.roles = #kept > 0 and kept or nil
    end
  end
  return true
end

--- Give a computer its computer roles (replaces the old list; empty clears it).
-- @tparam string hostname
-- @tparam {string...} roles
function Directory:assign_computer_roles(hostname, roles)
  local computer = self.data.computers[hostname]
  if not computer then
    return nil, "no such computer"
  end
  if #roles > directory.MAX_ROLES_PER_COMPUTER then
    return nil, "at most " .. directory.MAX_ROLES_PER_COMPUTER .. " computer roles per computer"
  end
  for _, role in ipairs(roles) do
    if not self.data.computer_roles[role] then
      return nil, "no such computer role: " .. tostring(role)
    end
  end
  computer.roles = #roles > 0 and roles or nil
  return true
end

--- @treturn {table...} { name, packages, settings, computers = { hostnames } } sorted by name.
function Directory:list_computer_roles()
  local list = {}
  for name, role in pairs(self.data.computer_roles) do
    local computers = {}
    for hostname, computer in pairs(self.data.computers) do
      for _, assigned in ipairs(computer.roles or {}) do
        if assigned == name then
          computers[#computers + 1] = hostname
        end
      end
    end
    table.sort(computers)
    list[#list + 1] = {
      name = name,
      packages = role.packages,
      settings = role.settings,
      computers = computers,
    }
  end
  table.sort(list, function(a, b) return a.name < b.name end)
  return list
end

--- What one computer should have: its roles merged (packages joined, later roles'
-- settings win).
-- @tparam string hostname
-- @treturn table|nil { roles, packages, settings }
function Directory:computer_config(hostname)
  local computer = self.data.computers[hostname]
  if not computer then
    return nil
  end
  local packages, seen, settings = {}, {}, {}
  for _, name in ipairs(computer.roles or {}) do
    local role = self.data.computer_roles[name]
    if role then
      for _, package in ipairs(role.packages) do
        if not seen[package] then
          seen[package] = true
          packages[#packages + 1] = package
        end
      end
      for key, value in pairs(role.settings or {}) do
        settings[key] = value
      end
    end
  end
  table.sort(packages)
  return { roles = computer.roles or {}, packages = packages, settings = settings }
end

------------------------------------------------------------------------------
-- Service records
------------------------------------------------------------------------------

function Directory:add_service(service_type, host, protocol)
  if not is_valid_name(service_type) then
    return nil, "invalid service type"
  end
  if not self.data.computers[host] then
    return nil, "no computer named " .. tostring(host) .. " in the domain"
  end
  self.data.services[service_type] = { host = host, protocol = protocol }
  return true
end

function Directory:remove_service(service_type)
  if not self.data.services[service_type] then
    return nil, "no such service record"
  end
  self.data.services[service_type] = nil
  return true
end

--- @tparam string service_type
-- @treturn table|nil { host, id, protocol }
function Directory:find_service(service_type)
  local service = self.data.services[service_type]
  if not service then
    return nil
  end
  return { host = service.host, id = self:resolve(service.host), protocol = service.protocol }
end

--- @treturn {table...} { type, host, protocol } sorted by type.
function Directory:list_services()
  local services = {}
  for service_type, service in pairs(self.data.services) do
    services[#services + 1] = {
      type = service_type,
      host = service.host,
      protocol = service.protocol,
    }
  end
  table.sort(services, function(a, b) return a.type < b.type end)
  return services
end

------------------------------------------------------------------------------
-- User sessions (in memory only)
------------------------------------------------------------------------------

--- Log a user in.
-- @tparam string name
-- @tparam string password
-- @tparam number now Seconds.
-- @treturn[1] table { token, name, groups, expires }
-- @treturn[2] nil
-- @treturn[2] string error message
-- @tparam[opt] number computer The computer ID the user logged in at (a mail server
--   announces new mail there).
function Directory:login(name, password, now, computer)
  if not self:check_password(name, password) then
    return nil, "Login incorrect."
  end
  local token = new_token()
  self.sessions[token] = { name = name, expires = now + directory.SESSION_SECONDS,
    computer = computer }
  return {
    token = token,
    name = name,
    groups = self:groups_of(name),
    expires = now + directory.SESSION_SECONDS,
  }
end

--- Who is behind a user token?
-- @tparam string token
-- @tparam number now
-- @treturn table|nil { name, groups }
function Directory:validate(token, now)
  local entry = type(token) == "string" and self.sessions[token]
  if not entry then
    return nil
  end
  if now >= entry.expires or not self.data.users[entry.name] then
    self.sessions[token] = nil
    return nil
  end
  return { name = entry.name, groups = self:groups_of(entry.name) }
end

function Directory:logout(token)
  self.sessions[token] = nil
  return true
end

function Directory:end_sessions_of(name)
  for token, entry in pairs(self.sessions) do
    if entry.name == name then
      self.sessions[token] = nil
    end
  end
end

--- The sessions, for saving (they survive a controller restart).
-- @treturn table [token] = { name, expires }
function Directory:saved_sessions()
  return self.sessions
end

--- Forget expired sessions (they are otherwise only dropped when used again).
-- @tparam number now
-- @treturn number How many were removed.
function Directory:prune_sessions(now)
  local removed = 0
  for token, entry in pairs(self.sessions) do
    if now >= entry.expires then
      self.sessions[token] = nil
      removed = removed + 1
    end
  end
  return removed
end

------------------------------------------------------------------------------
-- Health
------------------------------------------------------------------------------

local function count(map)
  local total = 0
  for _ in pairs(map) do
    total = total + 1
  end
  return total
end

--- Counts and sizes for the health check.
-- @treturn table { users, groups, computers, services, sessions, saved_bytes }
function Directory:stats()
  return {
    users = count(self.data.users),
    groups = count(self.data.groups),
    computers = count(self.data.computers),
    services = count(self.data.services),
    sessions = count(self.sessions),
    saved_bytes = #textutils.serialise(self.data),
  }
end

return directory
