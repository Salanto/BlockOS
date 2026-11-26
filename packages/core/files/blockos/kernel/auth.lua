--- User accounts and login providers.
--
-- Local accounts live in /etc/blockos/passwd. Other packages can add login
-- providers (the domain package adds "domain"); the session picks one from the
-- name typed at the login prompt.
--
-- Threat model (see CLAUDE.md): only friendly players use the network, so a
-- simple salted hash is enough. This is not cryptographic security.
-- @module auth

local fsx = import("fsx")
local paths = import("paths")

local auth = {}

local HASH_ROUNDS = 4
local UINT32 = 4294967296

--- Hash a password with a salt (shared with the domain controller).
-- @tparam string salt
-- @tparam string password
-- @treturn string
function auth.hash_password(salt, password)
  local input = salt .. ":" .. password
  local hash = 5381
  for _ = 1, HASH_ROUNDS do
    for i = 1, #input do
      hash = (hash * 33 + input:byte(i)) % UINT32
    end
  end
  return string.format("%08x", hash)
end

--- @treturn string A new random salt.
function auth.new_salt()
  return string.format("%08x", math.random(0, 0x7fffffff))
end

local function load_db()
  local db = fsx.read_table(paths.passwd())
  if type(db) ~= "table" or type(db.users) ~= "table" then
    return { users = {} }
  end
  return db
end

local function save_db(db)
  fsx.write_table(paths.passwd(), db)
end

local function public_record(name, user)
  return { name = name, is_admin = user.is_admin == true }
end

--- @tparam string name
-- @treturn boolean True if `name` is a valid user name.
function auth.is_valid_name(name)
  return type(name) == "string"
    and #name >= 1 and #name <= 16
    and name:match("^[%w_%-]+$") ~= nil
end

--- False when passwd is missing, empty or unreadable; callers then run setup.
-- @treturn boolean
function auth.has_users()
  return next(load_db().users) ~= nil
end

--- @treturn {table...} { name, is_admin } records, sorted by name.
function auth.list()
  local users = {}
  for name, user in pairs(load_db().users) do
    users[#users + 1] = public_record(name, user)
  end
  table.sort(users, function(a, b) return a.name < b.name end)
  return users
end

--- Look up a local account.
-- @tparam string name
-- @treturn table|nil { name, is_admin }
function auth.get(name)
  local user = load_db().users[name]
  return user and public_record(name, user)
end

--- Create an account.
-- @tparam string name
-- @tparam string password
-- @tparam boolean is_admin
-- @treturn[1] true
-- @treturn[2] nil
-- @treturn[2] string error message
function auth.add_user(name, password, is_admin)
  if not auth.is_valid_name(name) then
    return nil, "invalid user name (1-16 of A-Z a-z 0-9 _ -)"
  end
  if type(password) ~= "string" or password == "" then
    return nil, "password must not be empty"
  end
  local db = load_db()
  if db.users[name] then
    return nil, "user already exists"
  end
  local salt = auth.new_salt()
  db.users[name] = {
    salt = salt,
    hash = auth.hash_password(salt, password),
    is_admin = is_admin == true,
  }
  save_db(db)
  return true
end

--- Change a user's password.
-- @tparam string name
-- @tparam string password
-- @treturn[1] true
-- @treturn[2] nil
-- @treturn[2] string error message
function auth.set_password(name, password)
  if type(password) ~= "string" or password == "" then
    return nil, "password must not be empty"
  end
  local db = load_db()
  local user = db.users[name]
  if not user then
    return nil, "no such user"
  end
  user.salt = auth.new_salt()
  user.hash = auth.hash_password(user.salt, password)
  save_db(db)
  return true
end

--- Delete an account. The last administrator cannot be removed.
-- @tparam string name
-- @treturn[1] true
-- @treturn[2] nil
-- @treturn[2] string error message
function auth.remove_user(name)
  local db = load_db()
  if not db.users[name] then
    return nil, "no such user"
  end
  db.users[name] = nil

  local admin_count = 0
  for _, user in pairs(db.users) do
    if user.is_admin then
      admin_count = admin_count + 1
    end
  end
  if admin_count == 0 then
    return nil, "cannot remove the last administrator"
  end

  save_db(db)
  return true
end

--- Check a user name and password.
-- @tparam string name
-- @tparam string password
-- @treturn table|nil { name, is_admin } on success.
function auth.check(name, password)
  local user = load_db().users[name]
  if not user or type(password) ~= "string" then
    return nil
  end
  if auth.hash_password(user.salt, password) ~= user.hash then
    return nil
  end
  return public_record(name, user)
end

------------------------------------------------------------------------------
-- Login providers
--
-- A provider is a table:
--   describe()               short text for the login screen, e.g. "Domain: home"
--   is_available()           true if it can be used now (e.g. computer joined)
--   login(name, password)    -> user record, or nil and an error message
--   logout(user)             optional, best effort
-- User records: { name, source, groups = {...}, is_admin, token? }.
------------------------------------------------------------------------------

local providers = {}

local LOCAL_PREFIX = ".\\"

providers["local"] = {
  describe = function() return "Local accounts" end,
  is_available = function() return true end,
  login = function(name, password)
    local user = auth.check(name, password)
    if not user then
      return nil, "Login incorrect."
    end
    user.source = "local"
    user.groups = {}
    return user
  end,
}

--- Add a login provider.
-- @tparam string name e.g. "domain"
-- @tparam table provider
function auth.register_provider(name, provider)
  providers[name] = provider
end

--- @tparam string name
-- @treturn table|nil
function auth.provider(name)
  return providers[name]
end

--- The provider used for a bare user name: the domain when available.
-- @treturn string Provider name.
function auth.default_provider()
  local domain = providers.domain
  if domain and domain.is_available() then
    return "domain"
  end
  return "local"
end

--- Work out which provider a typed name refers to.
--
-- ".\name" is a local account, "domain\name" a domain account, and a bare name
-- uses the default provider.
-- @tparam string typed
-- @treturn[1] string provider name
-- @treturn[1] string user name
-- @treturn[2] nil
-- @treturn[2] string error message
function auth.parse_login_name(typed)
  if typed:sub(1, #LOCAL_PREFIX) == LOCAL_PREFIX then
    return "local", typed:sub(#LOCAL_PREFIX + 1)
  end
  local prefix, name = typed:match("^([^\\]+)\\(.+)$")
  if not prefix then
    return auth.default_provider(), typed
  end
  local domain = providers.domain
  if not (domain and domain.is_available() and domain.name and domain.name() == prefix) then
    return nil, "Unknown domain: " .. prefix
  end
  return "domain", name
end

--- Log in with a typed name and password.
-- @tparam string typed The name as typed (may include ".\" or "domain\").
-- @tparam string password
-- @treturn[1] table The user record.
-- @treturn[2] nil
-- @treturn[2] string error message
function auth.login(typed, password)
  local provider_name, name = auth.parse_login_name(typed)
  if not provider_name then
    return nil, name
  end
  return providers[provider_name].login(name, password)
end

--- End a login with its provider (best effort, never raises).
-- @tparam table user
function auth.logout(user)
  local provider = providers[user.source]
  if provider and provider.logout then
    pcall(provider.logout, user)
  end
end

--- Text for the login screen, e.g. "Domain: home (use .\name for local accounts)".
-- @treturn string|nil
function auth.login_hint()
  if auth.default_provider() == "domain" then
    return providers.domain.describe() .. " (use .\\name for local accounts)"
  end
  return nil
end

return auth
