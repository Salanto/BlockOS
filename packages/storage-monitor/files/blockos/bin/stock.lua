-- stock: watch stock and set up alarms.
--
--   stock                           full-screen tool (Overview, Catalog, Alarms,
--                                   Alerts, Access)
--   stock setup [--name <name>]     make this computer a stock computer
--   stock status | alerts           print the current state
--   stock board <peripheral>|off    show a stock board on a monitor or Display Link
--   stock access add|remove admin|viewer|computer <name>
--   stock sound note|sound|file <value> [volume] | test
--                                   alarm sound: a note block instrument, a
--                                   Minecraft sound event, or a .dfpwm audio file
--   --server <name>                 talk to the stock computer registered as
--                                   "stock-<name>" instead of "stock"
local args = { ... }
local ui = blockos.ui
local stock = import("stock")
local stock_client = import("stock_client")

local function print_usage()
  print("Usage: stock [--server <name>]")
  print("       stock setup [--name <name>]")
  print("       stock status | alerts")
  print("       stock board <peripheral> | off")
  print("       stock access add|remove admin|viewer|computer <name>")
  print("       stock sound note|sound|file <value> [volume] | test")
end

local function parse_args()
  local options = { words = {} }
  local i = 1
  while i <= #args do
    local flag = args[i]
    if flag == "--server" or flag == "--name" then
      options[flag:sub(3)] = args[i + 1]
      i = i + 1
    else
      options.words[#options.words + 1] = flag
    end
    i = i + 1
  end
  return options
end

local function fail(message)
  ui.print(tostring(message), "error")
end

local function connect(options)
  local connection, err = stock_client.connect(options.server)
  if not connection then
    fail(err)
  end
  return connection
end

------------------------------------------------------------------------------
-- stock setup
------------------------------------------------------------------------------

local function ask_yes(question, default_yes)
  write(question .. (default_yes and " [Y/n] " or " [y/N] "))
  local answer = read():lower()
  if answer == "" then
    return default_yes
  end
  return answer == "y"
end

local function split_names(text)
  local names = {}
  for name in text:gmatch("[^,%s]+") do
    names[#names + 1] = name
  end
  return names
end

local function register_service(name)
  local ok, domain = pcall(import, "domain")
  if not ok or not domain.is_joined() then
    ui.print("Not in a domain: other computers cannot find this one yet.", "warn")
    return
  end
  local record = {
    type = stock_client.service_type(name),
    host = blockos.net.hostname(),
    protocol = stock_client.PROTOCOL,
  }
  local result, err = domain.call("service_add", record)
  if result then
    ui.status("Registered as '" .. record.type .. "' in the domain.", "ok")
  else
    ui.print("Could not register the service record: " .. tostring(err), "warn")
    print("A domain admin can do it later with:")
    print("  domain dns add " .. record.type .. " " .. record.host .. " " .. record.protocol)
  end
end

local function setup(options)
  local fsx = import("fsx")
  local paths = import("paths")
  local stock_sources = import("stock_sources")
  local path = paths.top(stock_client.CONFIG_FILE)

  if not (blockos.user and blockos.user.is_admin) then
    fail("Only administrators can set up a stock computer.")
    return
  end
  if fs.exists(path) then
    ui.print("This computer is already a stock computer. Use 'stock' to change it.", "warn")
    return
  end

  ui.title("Stock computer setup")
  local default_admin = blockos.user.source == "domain" and blockos.user.name or "stock-admins"
  local typed = ui.prompt("Administrators (users/groups): ", { default = default_admin })
  local admins = split_names(typed)
  local config = stock.new_config(admins, options.name)

  local sources = stock_sources.load()
  local totals, blocks = stock_sources.read_all(sources)
  local item_count = 0
  for _ in pairs(totals) do
    item_count = item_count + 1
  end
  ui.field("Storage", blocks .. " blocks, " .. item_count .. " different items", nil, 9)

  if item_count > 0 and ask_yes("Watch all " .. item_count .. " items now in storage?", true) then
    local typed_percent = ui.prompt("Limit as % of the current count: ", { default = "50" })
    local percent = tonumber(typed_percent) or 50
    local added = stock.watch_from_contents(config, totals, percent / 100)
    ui.status("Watching " .. added .. " items.", "ok")
  end

  fsx.write_table(path, config)
  register_service(options.name)
  blockos.services.start("storage-monitor")
  ui.status("Stock computer ready. Run 'stock' to adjust limits and alarms.", "ok")
end

------------------------------------------------------------------------------
-- Printing commands
------------------------------------------------------------------------------

local function show_status(connection)
  local data, err = connection.call("status")
  if not data then
    return fail(err)
  end
  ui.title((data.title or "Stock") .. " (" .. connection.describe .. ")")
  ui.table({
    { title = "ITEM", key = "label" },
    { title = "COUNT", key = "count" },
    { title = "LIMIT", key = "limit" },
    { title = "STATE", key = function(row) return row.is_low and "LOW" or "ok" end },
  }, data.rows, function(row) return row.is_low and "error" or "text" end)
end

local function describe_alert(alert)
  local state = alert.is_low and "LOW" or "ok again"
  return string.format("%s: %s %d/%d", state, alert.label or alert.item, alert.count, alert.limit)
end

local function show_alerts(connection)
  local alerts, err = connection.call("alerts")
  if not alerts then
    return fail(err)
  end
  ui.title("Recent stock alerts")
  if #alerts == 0 then
    ui.print("  (none)", "faint")
  end
  for _, alert in ipairs(alerts) do
    ui.status(describe_alert(alert), alert.is_low and "error" or "ok")
  end
end

local function set_board(name)
  if not (blockos.user and blockos.user.is_admin) then
    return fail("Only administrators can change the board.")
  end
  if name == "off" then
    blockos.config.set("blockos.stock.board", nil)
    ui.print("Stock board turned off.", "ok")
    return
  end
  if not peripheral.isPresent(name) then
    return fail("No peripheral named " .. name)
  end
  blockos.config.set("blockos.stock.board", name)
  ui.print("Stock board shown on " .. name .. ".", "ok")
end

local SOUND_KINDS = { note = true, sound = true, file = true }

local function set_sound(connection, kind, value, volume)
  if kind == "test" then
    local ok, err = connection.call("test_sound")
    if not ok then
      return fail(err)
    end
    return ui.print("Played the alarm sound.", "ok")
  end
  if not SOUND_KINDS[kind] or not value then
    return print_usage()
  end
  local sound = { kind = kind, value = value, volume = tonumber(volume) or 1 }
  local ok, err = connection.call("settings", { sound = sound })
  if not ok then
    return fail(err)
  end
  ui.print("Alarm sound set to " .. kind .. " " .. value .. ".", "ok")
end

local ACCESS_LISTS = { admin = "admins", viewer = "viewers", computer = "computers" }

local function change_access(connection, action, kind, name)
  local list_name = ACCESS_LISTS[kind]
  if not list_name or not name or (action ~= "add" and action ~= "remove") then
    return print_usage()
  end
  local access, err = connection.call("access")
  if not access then
    return fail(err)
  end
  local list = {}
  for _, entry in ipairs(access[list_name]) do
    if entry ~= name then
      list[#list + 1] = entry
    end
  end
  if action == "add" then
    list[#list + 1] = name
  end
  local ok, set_error = connection.call("set_access", { [list_name] = list })
  if not ok then
    return fail(set_error)
  end
  ui.print((action == "add" and "Added " or "Removed ") .. name .. " (" .. kind .. ").", "ok")
end

------------------------------------------------------------------------------
-- The full-screen tool
------------------------------------------------------------------------------

local function run_tool(connection)
  local state = { tab = 1, rows = {}, list = ui.new_list(), message = nil, role = "dim" }

  local function set_message(text, role)
    state.message, state.role = text, role or "dim"
  end

  local function run(op, call_args, success)
    local result, err = connection.call(op, call_args)
    if result then
      set_message(success, "ok")
    else
      set_message(err, "error")
    end
    return result
  end

  -- Keys that work without a selected row.
  local ROWLESS_KEYS = { W = true, a = true, s = true, t = true }

  local function choose_sound()
    local kinds = { "note", "sound", "file" }
    local labels = { "Note block instrument", "Minecraft sound", "Audio file (.dfpwm)" }
    local examples = { "bell", "minecraft:block.bell.use", "/sounds/alert.dfpwm" }
    local choice = ui.menu({
      title = "Alarm sound",
      text = "A .dfpwm file plays any recording, e.g. an ALERT voice clip.",
      items = labels,
    })
    local answers = ui.form(labels[choice], {
      { label = "Value (" .. examples[choice] .. "): " },
      { label = "Volume 1-3: " },
    })
    if answers then
      local volume = tonumber(answers[2]) or 1
      local sound = { kind = kinds[choice], value = answers[1], volume = volume }
      run("settings", { sound = sound }, "Alarm sound changed.")
    end
  end

  local function load_watches()
    local data = connection.call("watches")
    return data and data.watches or {}
  end

  local tabs = {}

  tabs[1] = {
    title = "Overview",
    load = function()
      local data, err = connection.call("status")
      return data and data.rows, err
    end,
    describe = function(row)
      return string.format("%-18s %6d/%-6d %s", row.label, row.count, row.limit,
        row.is_low and "LOW" or "")
    end,
    role = function(row) return row.is_low and "error" or nil end,
    hints = { { "e", "Limit" }, { "d", "Unwatch" } },
    keys = {
      e = function(row)
        local answers = ui.form("Limit for " .. row.label, { { label = "Limit: " } })
        if answers then
          run("watch", { item = row.item, limit = tonumber(answers[1]) or 0 }, "Limit changed.")
        end
      end,
      d = function(row)
        if ui.confirm("Stop watching " .. row.label .. "?") then
          run("unwatch", { item = row.item }, "No longer watched.")
        end
      end,
    },
  }

  tabs[2] = {
    title = "Catalog",
    load = function() return connection.call("catalog") end,
    describe = function(row)
      return string.format("%-20s %7d %s", row.label, row.count, row.is_watched and "watched" or "")
    end,
    hints = { { "w", "Watch" }, { "W", "Watch all" } },
    keys = {
      w = function(row)
        local default = tostring(math.max(1, math.floor(row.count / 2)))
        local answers = ui.form("Watch " .. row.label .. " (now " .. row.count .. ")",
          { { label = "Limit (" .. default .. "): " } })
        if answers then
          local limit = tonumber(answers[1]) or tonumber(default)
          run("watch", { item = row.item, limit = limit }, row.label .. " is watched.")
        end
      end,
      W = function()
        local answers = ui.form("Watch everything", { { label = "Limit as % of count: " } })
        if answers then
          local share = (tonumber(answers[1]) or 50) / 100
          local result = run("watch_all", { share = share }, "Watching more items.")
          if result then
            set_message("Added " .. result.added .. " items.", "ok")
          end
        end
      end,
    },
  }

  tabs[3] = {
    title = "Alarms",
    load = function() return load_watches() end,
    describe = function(row)
      local outputs = {}
      for _, output in ipairs(row.outputs or {}) do
        outputs[#outputs + 1] = output.target .. ":" .. output.side
      end
      local shown = #outputs > 0 and table.concat(outputs, " ") or "-"
      return string.format("%-18s %s", row.label, shown)
    end,
    hints = { { "o", "Output" }, { "x", "Clear" }, { "s", "Sound" }, { "t", "Test" } },
    keys = {
      s = choose_sound,
      t = function() run("test_sound", nil, "Played the alarm sound.") end,
      o = function(row)
        local targets = connection.call("outputs")
        if not targets then
          return set_message("Only admins can change alarms.", "error")
        end
        local names = {}
        for index, target in ipairs(targets) do
          names[index] = target.target
        end
        local target_menu = { title = "Redstone output for " .. row.label, items = names }
        local target = targets[ui.menu(target_menu)]
        local side_menu = { title = "Side of " .. target.target, items = stock.SIDES }
        local side = stock.SIDES[ui.menu(side_menu)]
        local outputs = row.outputs or {}
        outputs[#outputs + 1] = { target = target.target, side = side }
        run("watch", { item = row.item, limit = row.limit, outputs = outputs }, "Output added.")
      end,
      x = function(row)
        run("watch", { item = row.item, limit = row.limit, outputs = {} }, "Outputs cleared.")
      end,
    },
  }

  tabs[4] = {
    title = "Alerts",
    load = function() return connection.call("alerts") end,
    describe = describe_alert,
    role = function(row) return row.is_low and "error" or "ok" end,
    hints = {},
    keys = {},
  }

  tabs[5] = {
    title = "Access",
    load = function()
      local access, err = connection.call("access")
      if not access then
        return nil, err
      end
      local rows = {}
      for kind, list_name in pairs(ACCESS_LISTS) do
        for _, name in ipairs(access[list_name]) do
          rows[#rows + 1] = { kind = kind, name = name }
        end
      end
      table.sort(rows, function(a, b) return a.kind .. a.name < b.kind .. b.name end)
      return rows
    end,
    describe = function(row) return string.format("%-9s %s", row.kind, row.name) end,
    hints = { { "a", "Add" }, { "d", "Remove" } },
    keys = {
      a = function()
        local kinds = { "admin", "viewer", "computer" }
        local kind = kinds[ui.menu({ title = "Add to the access list", items = kinds })]
        local answers = ui.form("Add " .. kind, { { label = "Name: " } })
        if answers then
          local result = connection.call("access")
          if result then
            local list = result[ACCESS_LISTS[kind]]
            list[#list + 1] = answers[1]
            run("set_access", { [ACCESS_LISTS[kind]] = list }, answers[1] .. " added.")
          end
        end
      end,
      d = function(row)
        if ui.confirm("Remove " .. row.name .. "?") then
          local result = connection.call("access")
          if result then
            local list = {}
            for _, name in ipairs(result[ACCESS_LISTS[row.kind]]) do
              if name ~= row.name then
                list[#list + 1] = name
              end
            end
            run("set_access", { [ACCESS_LISTS[row.kind]] = list }, row.name .. " removed.")
          end
        end
      end,
    },
  }

  local function refresh()
    local rows, err = tabs[state.tab].load()
    state.rows = rows or {}
    if not rows then
      set_message(err, "error")
    end
  end

  local function draw()
    local _, height = ui.size()
    ui.clear()
    ui.header(1, "Stock " .. ui.GLYPHS.dot .. " " .. connection.describe,
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
    ui.draw_list(state.list, lines, 3, height - 2)
    if state.message then
      ui.line(height - 1, state.message, state.role)
    end
    local hints = { { "q", "Quit" } }
    for _, hint in ipairs(tabs[state.tab].hints) do
      hints[#hints + 1] = hint
    end
    hints[#hints + 1] = { "r", "Refresh" }
    ui.footer(hints)
  end

  local function switch_tab(index)
    if tabs[index] then
      state.tab = index
      state.list = ui.new_list()
      set_message(nil)
      refresh()
    end
  end

  refresh()
  while true do
    draw()
    local event, value = os.pullEvent()
    if event == "char" then
      local number = tonumber(value)
      if number then
        switch_tab(number)
      elseif value == "q" then
        break
      elseif value == "r" then
        set_message(nil)
        refresh()
      else
        local action = tabs[state.tab].keys[value]
        local row = state.rows[state.list.selected]
        if action and (row or ROWLESS_KEYS[value]) then
          action(row)
          refresh()
        end
      end
    elseif event == "key" then
      local _, height = ui.size()
      if value == keys.tab then
        switch_tab(state.tab % #tabs + 1)
      else
        ui.list_key(state.list, value, #state.rows, height - 4)
      end
    end
  end
  ui.clear()
end

------------------------------------------------------------------------------

local REMOTE_COMMANDS = { status = true, alerts = true, access = true, sound = true }

local options = parse_args()
local command = options.words[1]

if command == "setup" then
  setup(options)
elseif command == "board" then
  if options.words[2] then
    set_board(options.words[2])
  else
    print_usage()
  end
elseif command == nil or REMOTE_COMMANDS[command] then
  local connection = connect(options)
  if not connection then
    return
  end
  if command == "status" then
    show_status(connection)
  elseif command == "alerts" then
    show_alerts(connection)
  elseif command == "access" then
    change_access(connection, options.words[2], options.words[3], options.words[4])
  elseif command == "sound" then
    set_sound(connection, options.words[2], options.words[3], options.words[4])
  else
    run_tool(connection)
  end
else
  print_usage()
end
