-- domain: join or leave a domain, set packages up for it, and (with the domain-tools
-- package) manage it from the command line; dsa is the full-screen tool.
local args = { ... }
local ui = blockos.ui
local domain = import("domain")

local function print_usage()
  print("Usage: domain status")
  print("       domain join <domain> | leave [--force]")
  print("       domain update            check this computer's roles and updates now")
  print("       domain update --plan     show what that would change, change nothing")
  print("       domain user|group|computer|dns|setup ...   (package domain-tools)")
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

local ADMIN_COMMANDS = { user = true, group = true, computer = true, dns = true,
  setup = true }

local command = args[1]
if command == "status" or command == nil then
  show_status()
elseif command == "join" then
  join(args[2])
elseif command == "leave" then
  leave(args[2] == "--force")
elseif not domain.is_joined() then
  fail("This computer is not in a domain.")
elseif ADMIN_COMMANDS[command] then
  -- Managing the domain lives in domain-tools (only admins' computers need it).
  local found, admin = pcall(import, "domain_admin_cli")
  if not found then
    fail("Managing the domain needs the domain-tools package: pkg install domain-tools")
  else
    admin.run(args)
  end
elseif command == "update" and args[2] == "--plan" then
  local computer_config = import("computer_config")
  local preview, err = computer_config.preview()
  if not preview then
    fail(err)
  else
    ui.title("Plan for this computer (roles: " .. (#preview.roles > 0
      and table.concat(preview.roles, ", ") or "none") .. ")")
    for _, line in ipairs(computer_config.plan_lines(preview)) do
      ui.print(line.text, line.role)
    end
  end
elseif command == "update" then
  os.queueEvent(import("computer_config").UPDATE_NOW_EVENT)
  ui.print("Checking this computer's roles and updates; it reboots if anything changes.", "ok")
else
  print_usage()
end
