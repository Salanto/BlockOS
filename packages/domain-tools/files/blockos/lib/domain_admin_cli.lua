--- The admin subcommands of `domain` (user, group, computer, dns, setup), from the
-- domain-tools package: only computers where someone manages the domain need them.
-- @module domain_admin_cli

local domain = import("domain")
local ui = import("ui")

local domain_admin_cli = {}

local function fail(message)
  ui.print(tostring(message), "error")
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

-- "true"/"false" and numbers become real values; everything else stays text.
local function setting_value(text)
  if text == nil then
    return nil
  elseif text == "true" or text == "false" then
    return text == "true"
  end
  return tonumber(text) or text
end

local function find_computer_role(name)
  local roles, err = domain.call("list_computer_roles")
  if not roles then
    return nil, err
  end
  for _, role in ipairs(roles) do
    if role.name == name then
      return role
    end
  end
  return nil, "no such computer role: " .. name
end

local function computer_role_command(action, words)
  if action == "roles" then
    local roles, err = domain.call("list_computer_roles")
    if not roles then
      return fail(err)
    end
    ui.title("Computer roles")
    ui.table({
      { title = "ROLE", key = "name" },
      { title = "PACKAGES", key = function(role) return table.concat(role.packages, ", ") end },
      { title = "COMPUTERS", key = function(role) return table.concat(role.computers, ", ") end },
    }, roles)
  elseif action == "role" and words[3] then
    local existing = find_computer_role(words[3])
    local packages = { table.unpack(words, 4) }
    call("computer_role_set", { name = words[3], packages = packages,
      settings = existing and existing.settings or nil }, "Computer role " .. words[3] .. " saved.")
  elseif action == "role-del" and words[3] then
    call("computer_role_del", { name = words[3] }, "Computer role " .. words[3] .. " deleted.")
  elseif action == "setting" and words[4] then
    local role, err = find_computer_role(words[3])
    if not role then
      return fail(err)
    end
    local settings = {}
    for key, value in pairs(role.settings or {}) do
      settings[key] = value
    end
    settings[words[4]] = setting_value(words[5])
    call("computer_role_set", { name = role.name, packages = role.packages, settings = settings },
      "Setting saved.")
  elseif action == "assign" and words[3] then
    call("computer_assign", { hostname = words[3], roles = { table.unpack(words, 4) } },
      words[3] .. " applies its roles within 30 minutes ('domain update' there does it now).")
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
      { title = "ROLES", key = function(host) return table.concat(host.roles or {}, ", ") end },
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
      rows[#rows + 1] = { name = roles.family(name), mode = roles.mode(name),
        roles = table.concat(names, ", ") }
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

--- Run `domain <command> ...` for an admin subcommand.
-- @tparam {string...} args The command's words (args[1] is the subcommand).
-- @treturn boolean false when the subcommand is not one of these
function domain_admin_cli.run(args)
  local command = args[1]
  if command == "user" then
    user_command(args[2], args[3])
  elseif command == "group" then
    group_command(args[2], args[3], args[4])
  elseif command == "computer" and (args[2] == "list" or args[2] == "remove") then
    computer_command(args[2], args[3])
  elseif command == "computer" then
    computer_role_command(args[2], args)
  elseif command == "dns" then
    dns_command(args[2], args[3], args[4], args[5])
  elseif command == "setup" then
    setup(args[2])
  else
    return false
  end
  return true
end

return domain_admin_cli
