--- Domain membership and the client side of the domain controller protocol.
--
-- The membership is stored in /etc/blockos/domain:
--   { name, controller_id, computer_token }
-- The computer token is long-lived: it identifies this computer to the
-- controller (status reports, logging users in) until the computer account is
-- removed or the computer leaves the domain.
-- @module domain

local fsx = import("fsx")
local paths = import("paths")
local rpc = import("rpc")

local domain = {}

domain.PROTOCOL = "blockos.domain"
domain.ADMINS = "domain-admins"

local function membership_path()
  return paths.top("etc/blockos/domain")
end

--- @treturn table|nil { name, controller_id, computer_token } when joined.
function domain.membership()
  return fsx.read_table(membership_path())
end

--- @treturn boolean
function domain.is_joined()
  return domain.membership() ~= nil
end

--- @treturn string|nil The domain name.
function domain.name()
  local membership = domain.membership()
  return membership and membership.name
end

local function save_membership(membership)
  fsx.write_table(membership_path(), membership)
end

rpc.set_computer_token_provider(function()
  local membership = domain.membership()
  return membership and membership.computer_token
end)

-- When a program finds the login expired (e.g. after 24 hours), ask for the
-- password once instead of failing.
rpc.set_relogin_handler(function()
  local user = blockos and blockos.user
  if not (user and user.source == "domain") then
    return nil
  end
  local ui = blockos.ui
  ui.print("Your login has expired.", "warn")
  local ok, password = pcall(ui.prompt, "Password for " .. user.name .. ": ", { mask = "*" })
  if not ok then
    return nil
  end
  local session = domain.login(user.name, password)
  if not session then
    ui.print("Login incorrect.", "error")
    return nil
  end
  user.token = session.token
  user.groups = session.groups
  user.is_admin = domain.is_admin(user)
  return session.token
end)

-- Call the controller. If it stops answering (for example it was moved and now
-- has another computer ID), look it up again by domain name once.
local function call(op, args, options)
  local membership = domain.membership()
  if not membership then
    return nil, "this computer is not in a domain"
  end
  local result, err = rpc.call(membership.controller_id, domain.PROTOCOL, op, args, options)
  if result or not tostring(err):find("no answer") then
    return result, err
  end

  local found = rpc.find(domain.PROTOCOL, membership.name)
  if not found or found == membership.controller_id then
    return nil, "the domain controller for " .. membership.name .. " is unreachable"
  end
  membership.controller_id = found
  save_membership(membership)
  return rpc.call(found, domain.PROTOCOL, op, args, options)
end

--- Call any controller operation (used by the domain and dsa tools).
-- @tparam string op
-- @param[opt] args
-- @treturn[1] The result.
-- @treturn[2] nil
-- @treturn[2] string error message
function domain.call(op, args)
  return call(op, args, { relogin = true })
end

--- Join a domain. Needs the name and password of any domain user.
-- @tparam string domain_name
-- @tparam string hostname This computer's hostname.
-- @tparam string admin_name
-- @tparam string admin_password
-- @treturn[1] true
-- @treturn[2] nil
-- @treturn[2] string error message
function domain.join(domain_name, hostname, admin_name, admin_password)
  if domain.is_joined() then
    return nil, "already in domain " .. domain.name() .. "; leave it first"
  end
  local controller_id = rpc.find(domain.PROTOCOL, domain_name)
  if not controller_id then
    return nil, "no domain controller for " .. domain_name .. " answered"
  end
  local result, err = rpc.call(controller_id, domain.PROTOCOL, "join", {
    hostname = hostname,
    admin_name = admin_name,
    admin_password = admin_password,
  })
  if not result then
    return nil, err
  end
  save_membership({
    name = domain_name,
    controller_id = controller_id,
    computer_token = result.computer_token,
  })
  return true
end

--- Write the membership directly (used by dcpromo on the controller itself).
-- @tparam table membership { name, controller_id, computer_token }
function domain.set_membership(membership)
  save_membership(membership)
end

--- Leave the domain. Needs the same rights as joining.
-- @tparam string admin_name
-- @tparam string admin_password
-- @tparam[opt] boolean force Leave locally even if the controller is unreachable.
function domain.leave(admin_name, admin_password, force)
  local result, err = call("leave", { admin_name = admin_name, admin_password = admin_password })
  if not result and not force then
    return nil, err
  end
  fsx.delete(membership_path())
  return true
end

--- Log a domain user in through the controller.
-- @treturn[1] table { token, name, groups, expires }
-- @treturn[2] nil
-- @treturn[2] string error message
function domain.login(name, password)
  return call("login", { name = name, password = password })
end

--- Who is behind a user token? Asks the controller every time (no cache).
-- @tparam string token
-- @treturn table|nil { name, groups }
function domain.validate(token)
  return call("validate", { token = token })
end

--- Which domain computer does a computer token belong to?
-- @tparam string computer_token
-- @treturn table|nil { hostname }
function domain.validate_computer(computer_token)
  return call("validate_computer", { computer_token = computer_token })
end

--- End a user session at the controller.
function domain.logout(token)
  return call("logout", { token = token })
end

--- Report this computer's status (host record heartbeat).
-- @tparam table report { hostname, info, kind, version }
function domain.report(report)
  report.id = os.getComputerID()
  return call("host_update", report)
end

--- @tparam string hostname Short hostname.
-- @treturn number|nil Computer ID.
function domain.resolve(hostname)
  local result = call("resolve", { hostname = hostname })
  if type(result) == "table" then
    return result.id
  end
  return nil
end

--- Register a service record pointing at this computer (needs no admin: the
-- computer's own token is enough). Services call this when they start.
-- @tparam string service_type e.g. "pkg", "stock"
-- @tparam[opt] string protocol
-- @treturn[1] true
-- @treturn[2] nil
-- @treturn[2] string error message
function domain.register_service(service_type, protocol)
  return call("service_register", { type = service_type, protocol = protocol })
end

local function add_names(known, list)
  if type(list) ~= "table" then
    return false
  end
  for _, entry in ipairs(list) do
    known[entry.name] = true
  end
  return true
end

--- Names in an access list that no longer exist in the domain, e.g. a group
-- that was deleted. Access lists on other computers are not updated when a
-- group goes, so tools use this to point such entries out.
-- @tparam {string...} names
-- @tparam[opt] boolean include_users Users count as known too (lists that
--   take users and groups).
-- @treturn[1] {string...} The unknown names ("*" always counts as known).
-- @treturn[2] nil When it cannot be checked (not joined, no domain login,
--   controller unreachable).
function domain.find_unknown(names, include_users)
  if not domain.is_joined() then
    return nil
  end
  local known = { ["*"] = true }
  if not add_names(known, call("list_groups")) then
    return nil
  end
  if include_users and not add_names(known, call("list_users")) then
    return nil
  end
  local unknown = {}
  for _, name in ipairs(names) do
    if not known[name] then
      unknown[#unknown + 1] = name
    end
  end
  return unknown
end

--- Remove a service record pointing at this computer (e.g. after a rename).
-- @tparam string service_type e.g. "stock"
-- @treturn[1] true
-- @treturn[2] nil
-- @treturn[2] string error message
function domain.unregister_service(service_type)
  return call("service_unregister", { type = service_type })
end

--- @tparam string service_type e.g. "pkg"
-- @treturn table|nil { host, id, protocol }
function domain.find_service(service_type)
  local result = call("service_find", { type = service_type })
  if type(result) == "table" and result.id then
    return result
  end
  return nil
end

--- @treturn {table...}|nil Host records { hostname, id, kind, version, info, age }.
function domain.list_hosts()
  return call("list_hosts")
end

--- When a computer was last seen, for lists: "12s ago", "3d ago" or "never",
-- plus " (stale)" when it has not been seen for a week.
-- @tparam table host A host record from list_hosts / list_computers.
-- @treturn string
function domain.describe_seen(host)
  local text = "never"
  if host.age then
    text = math.floor(host.age) .. "s ago"
  elseif host.days_unseen then
    text = host.days_unseen .. "d ago"
  end
  if host.is_stale then
    text = text .. " (stale)"
  end
  return text
end

--- Disk and directory health of the controller, as rows to show.
-- @tparam table status From the dc_status operation.
-- @treturn {table...} { label, value, role } rows.
function domain.describe_health(status)
  local rows = {
    { label = "Users", value = status.users },
    { label = "Groups", value = status.groups },
    { label = "Computers", value = status.computers },
    { label = "Services", value = status.services },
    { label = "Sessions", value = status.sessions .. " in memory" },
    { label = "Saved size", value = status.saved_bytes .. " bytes" },
  }
  if status.free then
    local disk = status.free .. " bytes free"
    if status.capacity then
      disk = disk .. " of " .. status.capacity
    end
    rows[#rows + 1] = { label = "Disk", value = disk, role = status.has_room and "ok" or "error" }
  end
  if not status.has_room then
    rows[#rows + 1] = { label = "Warning", value = "disk full, changes refused", role = "error" }
  end
  return rows
end

--- @tparam table user A user record.
-- @treturn boolean True if the user is a domain admin.
function domain.is_admin(user)
  for _, group in ipairs(user.groups or {}) do
    if group == domain.ADMINS then
      return true
    end
  end
  return false
end

--- The login provider for the session (see auth.register_provider).
-- @treturn table
function domain.login_provider()
  return {
    describe = function() return "Domain: " .. tostring(domain.name()) end,
    is_available = domain.is_joined,
    name = domain.name,
    login = function(name, password)
      local session, err = domain.login(name, password)
      if not session then
        if tostring(err):find("unreachable") then
          return nil, "Domain controller unreachable; use .\\name for local accounts."
        end
        return nil, err
      end
      local user = {
        name = session.name,
        source = "domain",
        domain = domain.name(),
        groups = session.groups,
        token = session.token,
      }
      user.is_admin = domain.is_admin(user)
      return user
    end,
    logout = function(user)
      domain.logout(user.token)
    end,
  }
end

--- The directory for net (name lookups and the host list).
-- @treturn table
function domain.net_directory()
  return {
    name = domain.name,
    resolve = domain.resolve,
    list_hosts = domain.list_hosts,
  }
end

return domain
