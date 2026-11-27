--- Request handlers of the domain controller (protocol "blockos.domain").
--
-- Kept apart from the service so tests can call them directly. Permissions:
--   join, leave                   name + password of any domain user (friends only:
--                                 joining is not guarded); leave also takes the
--                                 logged-in user's token
--   login, validate, logout,      a joined computer's token
--   validate_computer, host_update,
--   service_register,             (a computer registers services pointing at itself,
--   service_unregister            and removes only those)
--   resolve, service_find,        anyone
--   list_hosts
--   group_get                     a joined computer or a logged-in user (role info for
--                                 modules: does it exist, is it open to everyone)
--   group_addmember, group_rmmember, group_set_everyone, group_del
--                                 domain-admins, or members of the group's managed_by
--   group_add                     domain-admins, or a module's admins creating
--                                 <module>-... roles managed by themselves
--   computer_config               a joined computer: what it should have installed and set
--   profile_get, profile_set      the logged-in user's own roaming profile
--   route                         a joined computer (a mail server): who a message to a
--                                 user or group reaches, and where they are logged in
--   list_users, list_groups,      any logged-in domain user (read only)
--   list_computers, list_services,
--   list_computer_roles,
--   dc_status
--   everything else               a domain-admins user token
--
-- Every change first checks that the controller's disk has room to save it.
-- When it does not, the change is refused; reads, logins and lookups go on.
-- @module dc_handlers

local directory = import("directory")
local rpc = import("rpc")

-- Argument schemas of the operations (see wire.validate).
local NAME = { type = "string", max = 32 }
local ARGS = {
  leave = {
    admin_name = { type = "string", optional = true },
    admin_password = { type = "string", optional = true },
  },
  join = { hostname = NAME, admin_name = "string", admin_password = "string" },
  login = { name = "string", password = "string" },
  token = { token = "string" },
  computer_token = { computer_token = "string" },
  host_update = {
    hostname = NAME,
    info = { type = "table", optional = true },
    kind = { type = "string", optional = true },
    version = { type = "string", optional = true },
    -- notices.problems() of the computer; the controller raises them as alerts
    problems = { type = "table", max = 16, optional = true },
  },
  hostname = { hostname = NAME },
  service_type = { type = NAME },
  service = { type = NAME, host = NAME, protocol = { type = "string", optional = true } },
  service_register = { type = NAME, protocol = { type = "string", optional = true } },
  name = { name = NAME },
  user_password = { name = NAME, password = "string" },
  user_enable = { name = NAME, is_enabled = "boolean" },
  membership = { group = NAME, user = NAME },
  group_add = {
    name = NAME,
    everyone = { type = "boolean", optional = true },
    managed_by = { type = "string", max = 32, optional = true },
  },
  group_everyone = { group = NAME, everyone = "boolean" },
  group_manager = { group = NAME, managed_by = { type = "string", max = 32, optional = true } },
  computer_role = {
    name = NAME,
    packages = "table",
    settings = { type = "table", optional = true },
    -- keep only these: computers remove optional packages their roles do not list
    prune = { type = "boolean", optional = true },
  },
  computer_assign = { hostname = NAME, roles = "table" },
  route = { to = NAME },
  profile_set = {
    apps = { type = "table", optional = true },
    settings = { type = "table", optional = true },
  },
}

local dc_handlers = {}

dc_handlers.DISK_FULL = "the domain controller's disk is full; changes are refused until "
  .. "space is freed"

--- Build the handler table.
-- @tparam Directory dir
-- @tparam table storage
--   save()          write the directory; returns true or nil, err
--   has_room()      true if a save would fit
--   disk_status()   optional: { free, capacity } of the controller's disk
--   save_sessions() optional: persist user sessions
-- @tparam[opt] table clock { now = seconds function, today = day function }
-- @tparam[opt] table hooks
--   on_report(hostname, args)  a computer sent a status report (the controller's alert
--                              broker raises its problems)
-- @treturn table { [op] = function(request_ctx, args) }
function dc_handlers.new(dir, storage, clock, hooks)
  clock = clock or {}
  hooks = hooks or {}
  local now = clock.now or function() return math.floor(os.epoch("utc") / 1000) end
  local today = clock.today or function() return os.day("utc") end
  local handlers = {}

  local function computer_of(ctx)
    return dir:computer_by_token(ctx.computer_token)
  end

  local function require_computer(ctx)
    local hostname = computer_of(ctx)
    if not hostname then
      return nil, "this computer is not a member of the domain"
    end
    return hostname
  end

  local function require_user(ctx, groups)
    local user = dir:validate(ctx.token, now())
    if not user then
      return nil, "login required"
    end
    if not groups then
      return user
    end
    for _, group in ipairs(groups) do
      if dir:is_member(group, user.name) then
        return user
      end
    end
    return nil, "permission denied"
  end

  local function require_admin(ctx)
    return require_user(ctx, { directory.ADMINS })
  end

  -- Make a change only if it can be saved, then save it.
  local function change(operation)
    if not storage.has_room() then
      return nil, dc_handlers.DISK_FULL
    end
    local result, err = operation()
    if not result then
      return nil, err
    end
    local saved, save_error = storage.save()
    if not saved then
      return nil, save_error
    end
    return result
  end

  -- Sessions are saved so logins survive a restart (best effort: a full disk
  -- only means people log in again after the next restart).
  local function save_sessions()
    if storage.save_sessions and storage.has_room() then
      storage.save_sessions()
    end
  end

  local with_args = rpc.with_args

  -- The operations are grouped in their own modules (sessions and joining, host and
  -- service records, directory management); they share these internals.
  local internal = {
    dir = dir, args = ARGS, now = now, today = today, with_args = with_args,
    computer_of = computer_of, require_computer = require_computer,
    require_user = require_user, require_admin = require_admin, change = change,
    save_sessions = save_sessions, storage = storage, hooks = hooks,
  }
  import("dc_sessions").attach(handlers, internal)
  import("dc_records").attach(handlers, internal)
  import("dc_admin").attach(handlers, internal)

  return handlers
end

return dc_handlers
