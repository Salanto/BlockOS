-- domain: join or leave a domain, and manage it from the command line.
-- (dsa offers the same management as a full-screen tool.)
local args = { ... }
local ui = blockos.ui
local domain = import("domain")

local function print_usage()
  print("Usage: domain status")
  print("       domain join <domain> | leave [--force]")
  print("       domain user add|del|passwd|enable|disable <name> | user list")
  print("       domain group add|del <name> | group list")
  print("       domain group addmember|rmmember <group> <user>")
  print("       domain group everyone <group> on|off | group manager <group> [group]")
  print("       domain setup [package]   set a package up for the domain (roles)")
  print("       domain computer list | computer remove <hostname>")
  print("       domain dns list | dns add <type> <host> [protocol] | dns del <type>")
end

local function fail(message)
  ui.print(tostring(message), "error")
end

local function is_local_admin()
  return blockos.user and blockos.user.is_admin
end

local function ask_admin_login(purpose)
  print(purpose .. ": log in with any domain account.")
  local name = ui.prompt("Name: ")
  local password = ui.prompt("Password: ", { mask = "*" })
  return name, password
end

local function show_status()
  local membership = domain.membership()
  if not membership then
    print("Not in a domain.")
    return
  end
  ui.title("Domain " .. membership.name)
  ui.field("Controller", "#" .. tostring(membership.controller_id), nil, 12)
  if blockos.net then
    ui.field("Full name", tostring(blockos.net.full_hostname()), nil, 12)
  end
  local is_domain_user = blockos.user and blockos.user.source == "domain"
  ui.field("Logged in", is_domain_user and "domain user" or "local user", nil, 12)

  local status, err = domain.call("dc_status")
  print()
  ui.title("Controller health")
  if type(status) ~= "table" then
    ui.status(tostring(err), "error")
    return
  end
  for _, line in ipairs(domain.describe_health(status)) do
    ui.field(line.label, line.value, line.role, 12)
  end
end

local function join(domain_name)
  if not domain_name then
    print_usage()
    return
  end
  if not is_local_admin() then
    fail("Only administrators can join this computer to a domain.")
    return
  end
  local name, password = ask_admin_login("Joining " .. domain_name)
  local ok, err = domain.join(domain_name, blockos.net.hostname(), name, password)
  if not ok then
    fail(err)
    return
  end
  ui.print("Joined " .. domain_name .. ". Rebooting...", "ok")
  sleep(2)
  os.reboot()
end

local function leave(force)
  if not is_local_admin() then
    fail("Only administrators can remove this computer from its domain.")
    return
  end
  -- A logged-in domain user needs no password: their login is sent along.
  local name, password
  if blockos.user.source ~= "domain" then
    name, password = ask_admin_login("Leaving the domain")
  end
  local ok, err = domain.leave(name, password, force)
  if not ok then
    fail(err .. " (use --force to leave anyway)")
    return
  end
  ui.print("Left the domain. Rebooting...", "ok")
  sleep(2)
  os.reboot()
end

local function call(op, call_args, success)
  local result, err = domain.call(op, call_args)
  if not result then
    fail(err)
    return
  end
  ui.print(success, "ok")
end

local function user_command(action, name)
  if action == "list" then
    local users, err = domain.call("list_users")
    if not users then
      return fail(err)
    end
    ui.title("Users")
    ui.table({
      { title = "USER", key = "name" },
      { title = "STATE", key = function(user) return user.is_enabled and "on" or "off" end },
      { title = "GROUPS", key = function(user) return table.concat(user.groups, ", ") end },
    }, users, function(user) return user.is_enabled and "text" or "faint" end)
  elseif not name then
    print_usage()
  elseif action == "add" or action == "passwd" then
    local password = ui.prompt("Password: ", { mask = "*" })
    if ui.prompt("Repeat:   ", { mask = "*" }) ~= password then
      return fail("Passwords do not match.")
    end
    local op = action == "add" and "user_add" or "user_passwd"
    call(op, { name = name, password = password }, "Done.")
  elseif action == "del" then
    call("user_del", { name = name }, "User " .. name .. " removed.")
  elseif action == "enable" or action == "disable" then
    call("user_enable", { name = name, is_enabled = action == "enable" }, "Done.")
  else
    print_usage()
  end
end

local function describe_members(group)
  if group.everyone then
    return "everyone"
  end
  return table.concat(group.members, ", ")
end

local function group_command(action, first, second)
  if action == "list" then
    local groups, err = domain.call("list_groups")
    if not groups then
      return fail(err)
    end
    ui.title("Groups")
    ui.table({
      { title = "GROUP", key = "name" },
      { title = "MEMBERS", key = describe_members },
      { title = "MANAGED BY", key = function(group) return group.managed_by or "" end },
    }, groups)
  elseif action == "everyone" and (second == "on" or second == "off") then
    local is_on = second == "on"
    call("group_set_everyone", { group = first, everyone = is_on },
      first .. (is_on and " now includes everyone." or " now lists its members."))
  elseif action == "manager" and first then
    local done = second and (second .. " now manages " .. first .. ".")
      or ("Only domain admins manage " .. first .. ".")
    call("group_set_manager", { group = first, managed_by = second }, done)
  elseif action == "add" and first then
    call("group_add", { name = first }, "Group " .. first .. " created.")
  elseif action == "del" and first then
    call("group_del", { name = first }, "Group " .. first .. " removed.")
  elseif action == "addmember" and second then
    call("group_addmember", { group = first, user = second }, "Done.")
  elseif action == "rmmember" and second then
    call("group_rmmember", { group = first, user = second }, "Done.")
  else
    print_usage()
  end
end

local function computer_command(action, hostname)
  if action == "list" then
    local hosts, err = domain.call("list_computers")
    if not hosts then
      return fail(err)
    end
    ui.title("Computers")
    ui.table({
      { title = "HOST", key = "hostname" },
      { title = "ID", key = "id" },
      { title = "KIND", key = "kind" },
      { title = "SEEN", key = domain.describe_seen },
    }, hosts, function(host) return host.is_stale and "faint" or "text" end)
  elseif action == "remove" and hostname then
    call("computer_remove", { hostname = hostname }, "Computer " .. hostname .. " removed.")
  else
    print_usage()
  end
end

local function dns_command(action, service_type, host, protocol)
  if action == "list" then
    local services, err = domain.call("list_services")
    if not services then
      return fail(err)
    end
    ui.title("Service records")
    ui.table({
      { title = "SERVICE", key = "type" },
      { title = "HOST", key = "host" },
      { title = "PROTOCOL", key = "protocol" },
    }, services)
  elseif action == "add" and host then
    local record = { type = service_type, host = host, protocol = protocol }
    call("service_add", record, "Service " .. service_type .. " -> " .. host .. " added.")
  elseif action == "del" and service_type then
    call("service_del", { type = service_type }, "Service " .. service_type .. " removed.")
  else
    print_usage()
  end
end

------------------------------------------------------------------------------
-- domain setup: guided setup of a package's roles (managed mode)
------------------------------------------------------------------------------

-- A domain admin's token: the logged-in user if they are one, else a login just for this.
local function admin_token()
  local user = blockos.user
  if user and user.source == "domain" and user.token and domain.is_admin(user) then
    return user.token, user.name
  end
  print("Setting up roles needs a domain admin.")
  local name = ui.prompt("Domain admin: ")
  local password = ui.prompt("Password: ", { mask = "*" })
  local session, err = domain.login(name, password)
  if not session then
    return nil, err
  end
  if not domain.is_admin({ groups = session.groups }) then
    return nil, name .. " is not a domain admin"
  end
  return session.token, name
end

local function list_setups(roles)
  ui.title("Packages with roles")
  local rows = {}
  for name, entry in pairs(import("pkg").installed()) do
    if entry.roles and #entry.roles > 0 then
      local names = {}
      for _, role in ipairs(entry.roles) do
        names[#names + 1] = role.name
      end
      rows[#rows + 1] = { name = name, mode = roles.mode(name), roles = table.concat(names, ", ") }
    end
  end
  table.sort(rows, function(a, b) return a.name < b.name end)
  if #rows == 0 then
    ui.print("  (no installed package declares roles)", "faint")
    return
  end
  ui.table({
    { title = "PACKAGE", key = "name" },
    { title = "MODE", key = "mode" },
    { title = "ROLES", key = "roles" },
  }, rows, function(row) return row.mode == "unconfigured" and "warn" or "text" end)
  print("Run 'domain setup <package>' to set one up.")
end

local function setup(package)
  local roles = import("roles")
  if not package then
    return list_setups(roles)
  end
  local declared = roles.declared(package)
  if #declared == 0 then
    return fail(package .. " has no roles to set up.")
  end
  local token, admin = admin_token()
  if not token then
    return fail(admin)
  end
  ui.title("Set up " .. package .. " for the domain")
  print("Press Enter to keep the suggestion. Type 'everyone' or names.")
  local answers = {}
  for _, role in ipairs(declared) do
    print()
    ui.print(role.name, "title")
    if role.description then
      ui.print(role.description, "dim")
    end
    local suggestion = role.default == "everyone" and "everyone"
      or (role.default == "installer" and admin or "nobody")
    answers[role.name] = ui.prompt("Who? [" .. suggestion .. "] ")
  end
  local plan = roles.plan(declared, admin, answers)
  print()
  ui.title("This creates")
  for _, entry in ipairs(plan) do
    local who = entry.everyone and "everyone" or table.concat(entry.members, ", ")
    print("  " .. entry.name .. ": " .. (who ~= "" and who or "nobody yet"))
  end
  if ui.prompt("Create these roles? [Y/n] "):lower() == "n" then
    return ui.print("Nothing changed.", "dim")
  end
  local report = roles.apply(plan, function(op, call_args)
    return domain.call_as(token, op, call_args)
  end)
  for _, line in ipairs(report) do
    ui.status(line, line:find(": no such user") and "warn" or "ok")
  end
  ui.print(package .. " is now managed by the domain.", "ok")
  if blockos.notices then
    blockos.notices.roles = nil
  end
end

local command = args[1]
if command == "status" or command == nil then
  show_status()
elseif command == "join" then
  join(args[2])
elseif command == "leave" then
  leave(args[2] == "--force")
elseif not domain.is_joined() then
  fail("This computer is not in a domain.")
elseif command == "user" then
  user_command(args[2], args[3])
elseif command == "group" then
  group_command(args[2], args[3], args[4])
elseif command == "computer" then
  computer_command(args[2], args[3])
elseif command == "dns" then
  dns_command(args[2], args[3], args[4], args[5])
elseif command == "setup" then
  setup(args[2])
else
  print_usage()
end
