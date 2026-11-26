-- dsa: Directory Service Admin, a full-screen tool for the domain (after AD's
-- "Users and Computers"). Keyboard first; mouse clicks work on advanced devices.
--
--   1-4 / Tab   switch tab        Up/Down/PgUp/PgDn   move
--   r           refresh           q                   quit
--   Tab actions are shown on the bottom row.
-- Everyone in the domain can look; changes need a domain admin.
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
    help = "a add  d delete  p password  e enable/disable",
  },
  {
    title = "Groups",
    load = "list_groups",
    describe = function(group)
      return string.format("%-18s %s", group.name, table.concat(group.members, ","))
    end,
    help = "a add  d delete  m add member  x remove member",
  },
  {
    title = "Computers",
    load = "list_computers",
    describe = function(host)
      local seen = host.age and (math.floor(host.age) .. "s") or "-"
      return string.format("%-16s #%-5s %-8s %s", host.hostname, tostring(host.id), host.kind, seen)
    end,
    help = "d remove",
  },
  {
    title = "DNS",
    load = "list_services",
    describe = function(service)
      return string.format("%-14s -> %s", service.type, service.host)
    end,
    help = "a add service record  d delete",
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
  ui.bar(1, "dsa - domain " .. tostring(domain.name()))
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
  ui.line(height, tabs[state.tab].help .. "  r refresh  q quit", "dim")
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
}

actions[3] = {
  d = function(host)
    if host and ui.confirm("Remove computer " .. host.hostname .. " from the domain?") then
      run("computer_remove", { hostname = host.hostname }, host.hostname .. " removed.")
    end
  end,
}

actions[4] = {
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
