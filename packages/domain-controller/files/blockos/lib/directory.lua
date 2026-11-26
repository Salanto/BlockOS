--- The domain directory: users, groups, computers, host and service records,
-- and user sessions. Loosely modelled on Active Directory (see CLAUDE.md).
--
-- This module is pure logic over a data table, so it can be unit-tested; the
-- domain-controller service saves the data and serves it over rpc.
--
-- Data layout (saved to /etc/blockos/directory):
--   domain    "home"
--   users     [name] = { salt, hash, is_enabled }
--   groups    [name] = { members = { [user] = true } }
--   computers [hostname] = { id, token, last_seen_day }
--   services  [type] = { host, protocol }
-- Kept in memory only: user sessions, and what computers report about
-- themselves (info, kind, version, exact last-seen time). This keeps the saved
-- file small and avoids a disk write for every status report.
-- @module directory

local auth = import("auth")

local Directory = {}
Directory.__index = Directory

local directory = {}

directory.ADMINS = "domain-admins"
directory.USERS = "domain-users"
directory.JOINERS = "computer-joiners"
directory.DNS_ADMINS = "dns-admins"
directory.BUILTIN_GROUPS = {
  directory.ADMINS, directory.USERS, directory.JOINERS, directory.DNS_ADMINS,
}

directory.SESSION_SECONDS = 8 * 60 * 60

--- Largest status report (serialised info) a computer may send.
directory.MAX_INFO_BYTES = 1024

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
-- @treturn Directory
function directory.load(data)
  local self = setmetatable({}, Directory)
  self.data = data
  data.users = data.users or {}
  data.groups = data.groups or {}
  data.computers = data.computers or {}
  data.services = data.services or {}
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
  self.sessions = {}
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
  for _, group in pairs(self.data.groups) do
    group.members[name] = nil
  end
  self:end_sessions_of(name)
  return true
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

function Directory:add_group(name)
  if not is_valid_name(name) then
    return nil, "invalid group name"
  end
  if self.data.groups[name] then
    return nil, "group already exists"
  end
  self.data.groups[name] = { members = {} }
  return true
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
  return entry ~= nil and entry.members[user] == true
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

--- @treturn {table...} { name, members = {...}, is_builtin } sorted by name.
function Directory:list_groups()
  local groups = {}
  for name, group in pairs(self.data.groups) do
    local members = {}
    for member in pairs(group.members) do
      members[#members + 1] = member
    end
    table.sort(members)
    groups[#groups + 1] = { name = name, members = members, is_builtin = is_builtin(name) }
  end
  table.sort(groups, function(a, b) return a.name < b.name end)
  return groups
end

------------------------------------------------------------------------------
-- Computers and host records
------------------------------------------------------------------------------

--- May this user join computers to the domain?
function Directory:can_join(name, password)
  if not self:check_password(name, password) then
    return false
  end
  return self:is_member(directory.ADMINS, name) or self:is_member(directory.JOINERS, name)
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
-- moves the record to the new hostname if that name is free.
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
    }
  end
  table.sort(hosts, function(a, b) return a.hostname < b.hostname end)
  return hosts
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
function Directory:login(name, password, now)
  if not self:check_password(name, password) then
    return nil, "Login incorrect."
  end
  local token = new_token()
  self.sessions[token] = { name = name, expires = now + directory.SESSION_SECONDS }
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
