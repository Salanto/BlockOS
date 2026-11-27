-- dsa: Directory Service Admin, a full-screen tool for the domain (after AD's
-- "Users and Computers"). Keyboard first; mouse clicks work on advanced devices.
--
--   1-5 / Tab   switch tab        Up/Down/PgUp/PgDn   move
--   r           refresh           q                   quit
--   Tab actions are shown on the bottom row.
-- Everyone in the domain can look; changes need a domain admin, or for a module's roles
-- a member of the module's admin role (e.g. logistics-admins).
--
-- Computer roles are chosen by ticking lists (role_picker): a role's packages from what
-- the package source offers, and its computers from the domain's computers.
local ui = blockos.ui
local domain = import("domain")
local role_picker = import("role_picker")

if not domain.is_joined() then
  ui.print("This computer is not in a domain.", "error")
  return
end

local tabs = {
  {
    title = "Users",
    load = "list_users",
    describe = function(user)
      local state = user.is_enabled and "" or " [disabled]"
      return string.format("%-16s %s%s", user.name, table.concat(user.groups, ","), state)
    end,
    hints = { { "a", "Add" }, { "d", "Delete" }, { "p", "Password" }, { "e", "On/off" } },
  },
  {
    title = "Groups",
    load = "list_groups",
    describe = function(group)
      local members = group.everyone and "everyone" or table.concat(group.members, ",")
      local manager = group.managed_by and (" (by " .. group.managed_by .. ")") or ""
      return string.format("%-20s %s%s", group.name, members, manager)
    end,
    hints = { { "a", "Add" }, { "d", "Delete" }, { "m", "Member+" }, { "x", "Member-" },
      { "e", "Everyone" }, { "b", "Managed by" } },
  },
  {
    title = "Computers",
    load = "list_computers",
    describe = function(host)
      local seen = domain.describe_seen(host)
      local has_roles = #(host.roles or {}) > 0
      local roles = has_roles and ("  [" .. table.concat(host.roles, ",") .. "]") or ""
      return string.format("%-16s %-8s %s%s", host.hostname, host.kind, seen, roles)
    end,
    hints = { { "c", "Shell" }, { "i", "Info" }, { "o", "Roles" }, { "u", "Update" },
      { "b", "Reboot" }, { "s", "Service" }, { "l", "Log" }, { "d", "Remove" } },
  },
  {
    title = "Roles",
    load = "list_computer_roles",
    describe = function(role)
      local used = #role.computers > 0 and (" (" .. #role.computers .. " pc)") or ""
      return string.format("%-16s %s%s", role.name, table.concat(role.packages, ","), used)
    end,
    hints = { { "a", "Add" }, { "p", "Packages" }, { "c", "Computers" }, { "s", "Setting" },
      { "d", "Delete" } },
  },
  {
    title = "DNS",
    load = "list_services",
    describe = function(service)
      return string.format("%-14s -> %s", service.type, service.host)
    end,
    hints = { { "a", "Add record" }, { "d", "Delete" } },
  },
}

local app = nil -- the running tab app (tab_app), for status messages

local function set_message(text, role)
  if app then
    app.set_message(text, role)
  end
end

-- Run a controller operation and report the outcome (the list reloads afterwards).
local function run(op, args, success)
  local result, err = domain.call(op, args)
  if result then
    set_message(success, "ok")
  else
    set_message(err, "error")
  end
end

-- The domain's computers, with when they were last seen (for the checklists).
local function computers()
  local hosts, err = domain.call("list_computers")
  if not hosts then
    return nil, err
  end
  for _, host in ipairs(hosts) do
    host.seen = domain.describe_seen(host)
  end
  return hosts
end

-- Tick the computers that have a role, and assign the ones that changed.
local function choose_computers(role_name)
  local hosts, err = computers()
  if not hosts then
    set_message(err, "error")
    return
  end
  local changes = role_picker.pick_computers(role_name, hosts)
  if not changes then
    return
  end
  for _, change in ipairs(changes) do
    local ok, assign_error = domain.call("computer_assign", change)
    if not ok then
      set_message(change.hostname .. ": " .. tostring(assign_error), "error")
      return
    end
  end
  set_message(#changes == 0 and "No computers changed." or (#changes .. " computer(s) changed;"
    .. " they apply their roles within 30 minutes (u updates one now)."), "ok")
end

local actions = {}

actions[1] = {
  a = function()
    local answers = ui.form("Add user", {
      { label = "Name: " },
      { label = "Password: ", mask = "*" },
    })
    if answers then
      local user = { name = answers[1], password = answers[2] }
      run("user_add", user, "User " .. answers[1] .. " added.")
    end
  end,
  d = function(user)
    if user and ui.confirm("Delete user " .. user.name .. "?") then
      run("user_del", { name = user.name }, "User " .. user.name .. " deleted.")
    end
  end,
  p = function(user)
    if not user then
      return
    end
    local fields = { { label = "Password: ", mask = "*" } }
    local answers = ui.form("New password for " .. user.name, fields)
    if answers then
      run("user_passwd", { name = user.name, password = answers[1] }, "Password changed.")
    end
  end,
  e = function(user)
    if user then
      local enable = not user.is_enabled
      run("user_enable", { name = user.name, is_enabled = enable },
        user.name .. (enable and " enabled." or " disabled."))
    end
  end,
}

actions[2] = {
  a = function()
    local answers = ui.form("Add group", { { label = "Name: " } })
    if answers then
      run("group_add", { name = answers[1] }, "Group " .. answers[1] .. " added.")
    end
  end,
  d = function(group)
    if group and ui.confirm("Delete group " .. group.name .. "?") then
      run("group_del", { name = group.name }, "Group " .. group.name .. " deleted.")
    end
  end,
  m = function(group)
    if not group then
      return
    end
    local answers = ui.form("Add member to " .. group.name, { { label = "User: " } })
    if answers then
      run("group_addmember", { group = group.name, user = answers[1] }, "Member added.")
    end
  end,
  x = function(group)
    if not group then
      return
    end
    local answers = ui.form("Remove member from " .. group.name, { { label = "User: " } })
    if answers then
      run("group_rmmember", { group = group.name, user = answers[1] }, "Member removed.")
    end
  end,
  -- Everyone in the domain, now and later, or only the listed members.
  e = function(group)
    if group then
      local everyone = not group.everyone
      run("group_set_everyone", { group = group.name, everyone = everyone },
        group.name .. (everyone and " now includes everyone." or " now lists its members."))
    end
  end,
  -- Which group may change this one without a domain admin (empty: only domain admins).
  b = function(group)
    if not group then
      return
    end
    local answers = ui.form("Who manages " .. group.name,
      { { label = "Group (- = domain admins only): ", default = group.managed_by } })
    if answers then
      local manager = answers[1] ~= "-" and answers[1] or nil
      run("group_set_manager", { group = group.name, managed_by = manager },
        manager and (group.name .. " is managed by " .. manager .. ".")
          or (group.name .. " is managed by domain admins only."))
    end
  end,
}

-- Remote admin: ask the computer itself (protocol blockos.manage, domain admins only).
local function manage_call(host, op, call_args)
  local rpc = import("rpc")
  return rpc.call(host.id, import("manage").PROTOCOL, op, call_args,
    { relogin = true, retries = 0 })
end

local function wait_key(text)
  ui.print("")
  ui.print(text or "Press any key to go back.", "dim")
  os.pullEvent("key")
end

local function show_info(host)
  local status, err = manage_call(host, "status")
  if not status then
    return set_message(host.hostname .. ": " .. tostring(err), "error")
  end
  ui.clear()
  term.setCursorPos(1, 1)
  ui.title(status.hostname .. " (" .. status.kind .. ")")
  ui.field("Version", status.version, nil, 10)
  ui.field("Up", math.floor(status.uptime / 60) .. " min", nil, 10)
  ui.field("User", status.user or "nobody logged in", nil, 10)
  if status.disk and status.disk.capacity then
    local used = 100 - math.floor(100 * status.disk.free / math.max(1, status.disk.capacity))
    local disk_role = used > 90 and "error" or nil
    ui.field("Disk", used .. "% used, " .. status.disk.free .. " bytes free", disk_role, 10)
  end
  if status.fuel then
    ui.field("Fuel", tostring(status.fuel), nil, 10)
  end
  if status.position then
    local pos = status.position
    ui.field("Position", pos.x .. " " .. pos.y .. " " .. pos.z, nil, 10)
  end
  ui.field("Services", #status.services .. " (" .. status.failed .. " failed)",
    status.failed > 0 and "error" or "ok", 10)
  for _, service in ipairs(status.services) do
    if service.state == "failed" or service.state == "crashed" then
      ui.status(service.name .. ": " .. tostring(service.last_error), "error")
    end
  end
  for _, notice in ipairs(status.notices or {}) do
    ui.status(notice, "warn")
  end
  wait_key()
end

local function show_log(host)
  local lines, err = manage_call(host, "log", { lines = 15 })
  if not lines then
    return set_message(host.hostname .. ": " .. tostring(err), "error")
  end
  ui.clear()
  term.setCursorPos(1, 1)
  ui.title("Log of " .. host.hostname)
  for _, line in ipairs(lines) do
    ui.print(line, line:find(" ERROR ") and "error" or (line:find(" WARN ") and "warn" or "text"))
  end
  wait_key()
end

local function control_service(host)
  local status, err = manage_call(host, "status")
  if not status then
    return set_message(host.hostname .. ": " .. tostring(err), "error")
  end
  local names = {}
  for index, service in ipairs(status.services) do
    names[index] = service.name .. "  [" .. tostring(service.state) .. "]"
  end
  names[#names + 1] = "Cancel"
  local choice = ui.menu({ title = "Service on " .. host.hostname, items = names })
  local service = status.services[choice]
  if not service then
    return
  end
  local verbs = { "restart", "start", "stop", "cancel" }
  local items = { "Restart", "Start", "Stop", "Cancel" }
  local verb = verbs[ui.menu({ title = service.name, items = items })]
  if verb == "cancel" then
    return
  end
  local result, call_error = manage_call(host, "service", { name = service.name, action = verb })
  if result then
    set_message(service.name .. " on " .. host.hostname .. ": " .. tostring(result.state), "ok")
  else
    set_message(tostring(call_error), "error")
  end
end

actions[3] = {
  c = function(host)
    if host then
      shell.run("rsh", host.hostname)
    end
  end,
  i = function(host)
    if host then
      show_info(host)
    end
  end,
  l = function(host)
    if host then
      show_log(host)
    end
  end,
  s = function(host)
    if host then
      control_service(host)
    end
  end,
  u = function(host)
    if not host then
      return
    end
    local ok, err = manage_call(host, "update")
    local done = host.hostname .. " is checking its roles and updates now."
    set_message(ok and done or tostring(err), ok and "ok" or "error")
  end,
  b = function(host)
    if host and ui.confirm("Reboot " .. host.hostname .. "?") then
      local ok, err = manage_call(host, "reboot")
      local done = host.hostname .. " is rebooting."
      set_message(ok and done or tostring(err), ok and "ok" or "error")
    end
  end,
  -- Give a computer its computer roles; it installs and sets what they say by itself.
  o = function(host)
    if not host then
      return
    end
    local roles, err = domain.call("list_computer_roles")
    if not roles then
      set_message(err, "error")
      return
    end
    local chosen = role_picker.pick_roles(host, roles)
    if chosen then
      run("computer_assign", { hostname = host.hostname, roles = chosen },
        host.hostname .. " will apply its roles within 30 minutes (or update it now).")
    end
  end,
  d = function(host)
    if host and ui.confirm("Remove computer " .. host.hostname .. " from the domain?") then
      run("computer_remove", { hostname = host.hostname }, host.hostname .. " removed.")
    end
  end,
}

-- Computer roles: what computers with the role should have installed and set.
actions[4] = {
  -- A name, then tick its packages, then tick the computers that get it.
  a = function()
    local answers = ui.form("Add computer role", { { label = "Name (e.g. farm-display): " } })
    if not answers then
      return
    end
    local name = answers[1]
    local packages = role_picker.pick_packages(name, {})
    if not packages then
      set_message("Computer role " .. name .. " not added.", "dim")
      return
    end
    local ok, err = domain.call("computer_role_set", { name = name, packages = packages })
    if not ok then
      set_message(err, "error")
      return
    end
    set_message("Computer role " .. name .. " added.", "ok")
    choose_computers(name)
  end,
  p = function(role)
    if not role then
      return
    end
    local packages = role_picker.pick_packages(role.name, role.packages)
    if packages then
      run("computer_role_set", { name = role.name, packages = packages,
        settings = role.settings }, "Packages of " .. role.name .. " changed.")
    end
  end,
  c = function(role)
    if role then
      choose_computers(role.name)
    end
  end,
  s = function(role)
    if not role then
      return
    end
    local answers = ui.form("Setting for " .. role.name, {
      { label = "Key (blockos.*): " },
      { label = "Value (empty removes): " },
    })
    if answers then
      local settings = {}
      for key, value in pairs(role.settings or {}) do
        settings[key] = value
      end
      local value = answers[2]
      if value == "" then
        value = nil
      elseif value == "true" or value == "false" then
        value = value == "true"
      elseif tonumber(value) then
        value = tonumber(value)
      end
      settings[answers[1]] = value
      run("computer_role_set", { name = role.name, packages = role.packages, settings = settings },
        "Setting changed.")
    end
  end,
  d = function(role)
    if role and ui.confirm("Delete computer role " .. role.name .. "?") then
      run("computer_role_del", { name = role.name }, "Computer role " .. role.name .. " deleted.")
    end
  end,
}

actions[5] = {
  a = function()
    local answers = ui.form("Add service record", {
      { label = "Service type (e.g. pkg): " },
      { label = "Host: " },
      { label = "Protocol (optional): " },
    })
    if answers then
      local protocol = answers[3] ~= "" and answers[3] or nil
      run("service_add", { type = answers[1], host = answers[2], protocol = protocol },
        "Service record " .. answers[1] .. " added.")
    end
  end,
  d = function(service)
    if service and ui.confirm("Delete service record " .. service.type .. "?") then
      run("service_del", { type = service.type }, "Service record " .. service.type .. " deleted.")
    end
  end,
}

for index, tab in ipairs(tabs) do
  local op = tab.load
  tab.load = function() return domain.call(op) end
  tab.keys = actions[index]
  tab.rowless = { a = true } -- "add" works on an empty list
end

local health = domain.call("dc_status")
local disk_full = type(health) == "table" and not health.has_room
import("tab_app").run({
  title = function() return "Directory " .. ui.GLYPHS.dot .. " " .. tostring(domain.name()) end,
  right = function() return blockos.user and blockos.user.name end,
  tabs = tabs,
  message = disk_full and "The controller's disk is full: changes are refused." or nil,
  message_role = "error",
  on_start = function(running) app = running end,
})
