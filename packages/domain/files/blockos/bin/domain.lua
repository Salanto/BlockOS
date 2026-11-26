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
  print(purpose .. " needs a domain admin or computer-joiner.")
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
  print("Domain:     " .. membership.name)
  print("Controller: #" .. tostring(membership.controller_id))
  if blockos.net then
    print("Full name:  " .. tostring(blockos.net.full_hostname()))
  end
  local is_domain_user = blockos.user and blockos.user.source == "domain"
  print("Logged in:  " .. (is_domain_user and "domain user" or "local user"))
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
  local name, password = ask_admin_login("Leaving the domain")
  local ok, err = domain.leave(name, password, force)
  if not ok then
    fail(err .. " (use --force to leave anyway)")
    return
  end
  ui.print("Left the domain. Rebooting...", "ok")
  sleep(2)
  os.reboot()
end

local function print_list(rows, describe)
  for _, row in ipairs(rows) do
    print(describe(row))
  end
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
    print_list(users, function(user)
      local state = user.is_enabled and "" or " (disabled)"
      return string.format("%-16s %s%s", user.name, table.concat(user.groups, ","), state)
    end)
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

local function group_command(action, first, second)
  if action == "list" then
    local groups, err = domain.call("list_groups")
    if not groups then
      return fail(err)
    end
    print_list(groups, function(group)
      return string.format("%-18s %s", group.name, table.concat(group.members, ","))
    end)
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
    print_list(hosts, function(host)
      local seen = host.age and (math.floor(host.age) .. "s ago") or "never"
      return string.format("%-16s #%-5s %-8s %s", host.hostname, tostring(host.id), host.kind, seen)
    end)
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
    print_list(services, function(service)
      local protocol = tostring(service.protocol or "")
      return string.format("%-14s -> %-16s %s", service.type, service.host, protocol)
    end)
  elseif action == "add" and host then
    local record = { type = service_type, host = host, protocol = protocol }
    call("service_add", record, "Service " .. service_type .. " -> " .. host .. " added.")
  elseif action == "del" and service_type then
    call("service_del", { type = service_type }, "Service " .. service_type .. " removed.")
  else
    print_usage()
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
else
  print_usage()
end
