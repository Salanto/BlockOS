--- Local user accounts.
--
-- Threat model (see CLAUDE.md): only friendly players use the network, so a
-- simple salted hash is enough. This is not cryptographic security.
-- @module auth

local fsx = import("fsx")
local paths = import("paths")

local auth = {}

local HASH_ROUNDS = 4
local UINT32 = 4294967296

local function hash_password(salt, password)
  local input = salt .. ":" .. password
  local hash = 5381
  for _ = 1, HASH_ROUNDS do
    for i = 1, #input do
      hash = (hash * 33 + input:byte(i)) % UINT32
    end
  end
  return string.format("%08x", hash)
end

local function new_salt()
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
  local salt = new_salt()
  db.users[name] = {
    salt = salt,
    hash = hash_password(salt, password),
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
  user.salt = new_salt()
  user.hash = hash_password(user.salt, password)
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
  if hash_password(user.salt, password) ~= user.hash then
    return nil
  end
  return public_record(name, user)
end

return auth
