-- dsa: Directory Service Admin, a full-screen tool for the domain (after AD's
-- "Users and Computers"). Keyboard first; mouse clicks work on advanced devices.
--
--   1-5 / Tab   switch tab        Up/Down/PgUp/PgDn   move
--   r           refresh           q                   quit
--   Tab actions are shown on the bottom row.
-- Everyone in the domain can look; changes need a domain admin, or for a module's roles
-- a member of the module's admin role (e.g. logistics-admins).
local ui = blockos.ui
local domain = import("domain")

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
      { "e", "Everyone" } },
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
    hints = { { "a", "Add" }, { "p", "Packages" }, { "s", "Setting" }, { "d", "Delete" } },
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

local state = {
  tab = 1,
  rows = {},
  list = ui.new_list(),
  message = nil,
  message_role = "dim",
}

local function set_message(text, role)
  state.message = text
  state.message_role = role or "dim"
end

local function refresh()
  local rows, err = domain.call(tabs[state.tab].load)
  if not rows then
    state.rows = {}
    set_message(err, "error")
    return
  end
  state.rows = rows
end

local function list_rows()
  local _, height = ui.size()
  return 3, height - 2
end

local function draw()
  local _, height = ui.size()
  ui.clear()
  ui.header(1, "Directory " .. ui.GLYPHS.dot .. " " .. tostring(domain.name()),
    blockos.user and blockos.user.name)
  local titles = {}
  for index, tab in ipairs(tabs) do
    titles[index] = tab.title
  end
  ui.tabs(2, titles, state.tab)

  local lines = {}
  for index, row in ipairs(state.rows) do
    lines[index] = tabs[state.tab].describe(row)
  end
  local top, bottom = list_rows()
  ui.draw_list(state.list, lines, top, bottom)

  if state.message then
    ui.line(height - 1, state.message, state.message_role)
  end
  -- Quit first: hints that do not fit on a small screen are dropped from the end.
  local hints = { { "q", "Quit" } }
  for _, hint in ipairs(tabs[state.tab].hints) do
    hints[#hints + 1] = hint
  end
  hints[#hints + 1] = { "r", "Refresh" }
  ui.footer(hints)
end

local function selected()
  return state.rows[state.list.selected]
end

-- Run a controller operation and report the outcome.
local function run(op, args, success)
  local result, err = domain.call(op, args)
  if result then
    set_message(success, "ok")
  else
    set_message(err, "error")
  end
  refresh()
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
}

local function split_words(text)
  local words = {}
  for word in tostring(text or ""):gmatch("[^,%s]+") do
    words[#words + 1] = word
  end
  return words
end

-- Remote admin: ask the computer itself (protocol blockos.manage, domain admins only).
local function manage_call(host, op, call_args)
  local rpc = import("rpc")
  return rpc.call(host.id, "blockos.manage", op, call_args, { relogin = true, retries = 0 })
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
      refresh()
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
    local current = table.concat(host.roles or {}, " ")
    local answers = ui.form("Computer roles of " .. host.hostname,
      { { label = "Roles (" .. (current ~= "" and current or "none") .. "): " } })
    if answers then
      local roles = answers[1] == "-" and {} or split_words(answers[1])
      run("computer_assign", { hostname = host.hostname, roles = roles },
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
  a = function()
    local answers = ui.form("Add computer role", {
      { label = "Name: " },
      { label = "Packages: " },
    })
    if answers then
      run("computer_role_set", { name = answers[1], packages = split_words(answers[2]) },
        "Computer role " .. answers[1] .. " added.")
    end
  end,
  p = function(role)
    if not role then
      return
    end
    local answers = ui.form("Packages of " .. role.name,
      { { label = "Packages (" .. table.concat(role.packages, " ") .. "): " } })
    if answers then
      run("computer_role_set", { name = role.name, packages = split_words(answers[1]),
        settings = role.settings }, "Packages changed.")
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

local function switch_tab(index)
  if tabs[index] and index ~= state.tab then
    state.tab = index
    state.list = ui.new_list()
    set_message(nil)
    refresh()
  end
end

local function on_char(char)
  local number = tonumber(char)
  if number then
    switch_tab(number)
    return true
  end
  if char == "q" then
    return false
  end
  if char == "r" then
    set_message(nil)
    refresh()
    return true
  end
  local action = actions[state.tab][char]
  if action then
    action(selected())
  end
  return true
end

local function on_click(y)
  local top, bottom = list_rows()
  if y >= top and y <= bottom then
    state.list.selected = state.list.scroll + (y - top) + 1
  end
end

refresh()
local health = domain.call("dc_status")
if type(health) == "table" and not health.has_room then
  set_message("The controller's disk is full: changes are refused.", "error")
end
while true do
  draw()
  local event, a, _, c = os.pullEvent()
  if event == "char" then
    if not on_char(a) then
      break
    end
  elseif event == "key" then
    if a == keys.tab then
      switch_tab(state.tab % #tabs + 1)
    elseif a == keys.delete and actions[state.tab].d then
      actions[state.tab].d(selected())
    else
      local top, bottom = list_rows()
      ui.list_key(state.list, a, #state.rows, bottom - top + 1)
    end
  elseif event == "mouse_click" then
    on_click(c)
  end
end
ui.clear()
