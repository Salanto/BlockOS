-- stock: watch stock and set up alarms.
--
--   stock                           full-screen tool (Overview, Catalog, Alarms,
--                                   Alerts, Access)
--   stock setup [--name <name>]     make this computer a stock computer
--   stock rename <name> | --clear   rename this stock computer (stock-<name>), or
--                                   go back to plain "stock"
--   stock status | alerts           print the current state
--   stock storage [list]            every inventory with its role and label
--   stock storage role <chest> storage|input|output|ignore
--   stock storage label <chest> <label...>   (nothing removes it)
--   stock request <item> [count] [output]    deliver items to an output chest
--   stock map                       the network map, with item moves animated
--   stock board <peripheral>|off    show a stock board on a monitor or Display Link
--   stock access add|remove admin|viewer|computer <name>
--   stock sound note|sound|file <value> [volume] | test
--                                   alarm sound: a note block instrument, a
--                                   Minecraft sound event, or a .dfpwm audio file
--   stock react add <item> <target> <side> | remove <item> | list
--                                   on THIS computer: a redstone output that stays
--                                   on while the item is low (e.g. run a farm until
--                                   it is refilled); target is "computer" or a relay
--   --server <name>                 talk to the stock computer registered as
--                                   "stock-<name>" instead of "stock"
local args = { ... }
local ui = blockos.ui
local stock = import("stock")
local stock_client = import("stock_client")

local function print_usage()
  print("Usage: stock [--server <name>]")
  print("       stock setup [--name <name>] | rename <name> | rename --clear")
  print("       stock status | alerts")
  print("       stock storage [list] | role <chest> <role> | label <chest> <label>")
  print("       stock request <item> [count] [output chest] | map")
  print("       stock board <peripheral> | off")
  print("       stock access add|remove admin|viewer|computer <name>")
  print("       stock sound note|sound|file <value> [volume] | test")
  print("       stock react add <item> <target> <side> | remove <item> | list")
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

-- The two usual reasons a stock computer sees no storage at all.
local NO_STORAGE_SHORT = "No storage found: right-click each wired modem"
local function print_no_storage_hint()
  ui.print("No storage found. Right-click each wired modem so it turns red,", "warn")
  ui.print("and put it on the storage's interface block (multiblocks).", "warn")
end

local function connect(options)
  local connection, err = stock_client.connect(options.server, { interactive = true })
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

  local name = nil
  if options.name then
    local err
    name, err = stock.check_name(options.name)
    if not name then
      fail(err)
      return
    end
  end

  ui.title("Stock computer setup")
  local default_admin = blockos.user.source == "domain" and blockos.user.name or "stock-admins"
  local typed = ui.prompt("Administrators (users/groups): ", { default = default_admin })
  local admins = split_names(typed)
  local config = stock.new_config(admins, name)

  local sources = stock_sources.load()
  local totals, blocks = stock_sources.read_all(sources)
  local item_count = 0
  for _ in pairs(totals) do
    item_count = item_count + 1
  end
  ui.field("Storage", blocks .. " blocks, " .. item_count .. " different items", nil, 9)
  if blocks == 0 then
    print_no_storage_hint()
  end

  if item_count > 0 and ask_yes("Watch all " .. item_count .. " items now in storage?", true) then
    local typed_percent = ui.prompt("Limit as % of the current count: ", { default = "50" })
    local percent = tonumber(typed_percent) or 50
    local added = stock.watch_from_contents(config, totals, percent / 100)
    ui.status("Watching " .. added .. " items.", "ok")
  end

  fsx.write_table(path, config)
  blockos.services.start("storage-monitor")
  ui.status("Stock computer ready. Run 'stock' to adjust limits and alarms.", "ok")
  ui.print("Everyone can look at it and every computer gets its alerts.", "dim")
  ui.print("To limit that, use the Access tab in 'stock'.", "dim")
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
  if data.sources == 0 then
    print_no_storage_hint()
  end
end

-- "12:04 LOW: Copper Ingot 0/1" (older stock computers send no time).
local function describe_alert(alert)
  local state = alert.is_low and "LOW" or "ok again"
  local time = alert.time and (alert.time .. " ") or ""
  return string.format("%s%s: %s %d/%d", time, state, alert.label or alert.item, alert.count,
    alert.limit)
end

-- Only the newest alert of an item is in colour; older ones are history.
local function alert_role(alert)
  if not alert.is_current then
    return "faint"
  end
  return alert.is_low and "error" or "ok"
end

local function load_alert_history(connection)
  local alerts, err = connection.call("alerts")
  return alerts and stock.alert_history(alerts), err
end

local function show_alerts(connection)
  local history, err = load_alert_history(connection)
  if not history then
    return fail(err)
  end
  ui.title("Recent stock alerts (newest first)")
  if #history == 0 then
    ui.print("  (none)", "faint")
  end
  for _, alert in ipairs(history) do
    ui.status(describe_alert(alert), alert_role(alert))
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

-- Find an item by its label or ID among the stock computer's watches.
local function find_item(connection, typed)
  local data, err = connection.call("status")
  if not data then
    return nil, err
  end
  -- Exact ID or label first, then any single label containing the text
  -- ("iron" finds "Iron Ingot"), so nobody has to type minecraft:iron_ingot.
  local wanted = typed:lower()
  local partial = {}
  for _, row in ipairs(data.rows) do
    local label = tostring(row.label):lower()
    if row.item == typed or label == wanted then
      return row
    end
    if label:find(wanted, 1, true) or row.item:find(wanted, 1, true) then
      partial[#partial + 1] = row
    end
  end
  if #partial == 1 then
    return partial[1]
  elseif #partial > 1 then
    return nil, "\"" .. typed .. "\" matches several items; be more specific"
  end
  return nil, "no watched item called " .. typed
end

local function show_reactions()
  local reactions = blockos.config.get("blockos.stock.reactions", {})
  ui.title("Reactions on this computer")
  ui.table({
    { title = "ITEM", key = "item" },
    { title = "OUTPUT", key = function(r) return r.target .. ":" .. r.side end },
  }, reactions)
end

-- stock react add <item> <target> <side> | remove <item> | list
local function change_reactions(connection, action, typed, target, side)
  if action == "list" or action == nil then
    return show_reactions()
  end
  if not (blockos.user and blockos.user.is_admin) then
    return fail("Only administrators can change reactions.")
  end
  if not typed then
    return print_usage()
  end
  local row, err = find_item(connection, typed)
  if not row then
    return fail(err)
  end
  local kept = {}
  for _, reaction in ipairs(blockos.config.get("blockos.stock.reactions", {})) do
    if reaction.item ~= row.item then
      kept[#kept + 1] = reaction
    end
  end
  if action == "add" then
    local ok, output_error = stock.validate_output({ target = target, side = side })
    if not ok then
      return fail(output_error)
    end
    kept[#kept + 1] = { item = row.item, target = target, side = side }
  elseif action ~= "remove" then
    return print_usage()
  end
  blockos.config.set("blockos.stock.reactions", kept)
  ui.print("Reactions updated.", "ok")
  show_reactions()
end

local ACCESS_LISTS = { admin = "admins", viewer = "viewers", computer = "computers" }

-- Access lists are not updated when a domain user or group is deleted; point
-- out entries that no longer exist (computer lists hold hostnames: skipped).
local function warn_unknown_names(list, kind)
  if kind == "computer" then
    return
  end
  local found, domain = pcall(import, "domain")
  local unknown = found and domain.find_unknown(list, true)
  if unknown and #unknown > 0 then
    ui.print("Not in the domain (deleted?): " .. table.concat(unknown, ", "), "warn")
  end
end

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
  warn_unknown_names(list, kind)
end

------------------------------------------------------------------------------
-- Logistics
------------------------------------------------------------------------------

local DEFAULT_REQUEST = 64

local function describe_fill(row)
  if not row.size then
    return "-"
  end
  return row.used .. "/" .. row.size .. " slots"
end

local function show_storages(connection)
  local rows, err = connection.call("storages")
  if not rows then
    return fail(err)
  end
  ui.title("Storage (" .. connection.describe .. ")")
  ui.table({
    { title = "CHEST", key = "label" },
    { title = "ROLE", key = "role" },
    { title = "FILL", key = describe_fill },
    { title = "NAME", key = "handle" },
  }, rows, function(row) return row.role == "ignore" and "faint" or "text" end)
end

local function change_storage(connection, words)
  local action, chest = words[2], words[3]
  if action == nil or action == "list" then
    return show_storages(connection)
  end
  if not chest or (action ~= "role" and action ~= "label") then
    return print_usage()
  end
  local call_args = { storage = chest }
  if action == "role" then
    call_args.role = words[4]
  else
    call_args.label = table.concat(words, " ", 4)
  end
  local result, err = connection.call("set_storage", call_args)
  if not result then
    return fail(err)
  end
  ui.print("Changed " .. result.storage .. ".", "ok")
end

local function describe_request(result, count)
  local text = string.format("Moved %d of %d %s to %s.", result.moved, count,
    tostring(result.label), tostring(result.output))
  return text, result.moved < count and "warn" or "ok"
end

local function request_items(connection, item, count_text, output)
  if not item then
    return print_usage()
  end
  local count = tonumber(count_text) or DEFAULT_REQUEST
  local result, err = connection.call("request", { item = item, count = count, output = output })
  if not result then
    return fail(err)
  end
  ui.print(describe_request(result, count))
end

------------------------------------------------------------------------------
-- The full-screen tool
------------------------------------------------------------------------------

local function show_map(connection)
  local ok, err = import("stock_map").run(connection)
  if not ok then
    fail(err)
  end
end

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
  local ROWLESS_KEYS = { W = true, a = true, s = true, t = true, f = true, m = true }

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
      if data and data.sources == 0 then
        set_message(NO_STORAGE_SHORT, "warn")
      end
      return data and data.rows, err
    end,
    describe = function(row)
      local target = row.refill_to and (" to " .. row.refill_to) or ""
      return string.format("%-18s %6d/%d%s %s", row.label, row.count, row.limit, target,
        row.is_low and "LOW" or "")
    end,
    role = function(row) return row.is_low and "error" or nil end,
    hints = { { "e", "Limit" }, { "f", "Refill to" }, { "d", "Unwatch" } },
    keys = {
      f = function(row)
        local answers = ui.form("Refill " .. row.label .. " to (0 = off)",
          { { label = "Refill to: " } })
        if answers then
          local refill_to = tonumber(answers[1]) or 0
          run("watch", { item = row.item, limit = row.limit, refill_to = refill_to },
            refill_to > 0 and ("Refills to " .. refill_to .. ".") or "Refill target removed.")
        end
      end,
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
    hints = { { "w", "Watch" }, { "W", "Watch all" }, { "g", "Get" } },
    keys = {
      g = function(row)
        local answers = ui.form("Get " .. row.label .. " (" .. row.count .. " stored)",
          { { label = "How many (" .. DEFAULT_REQUEST .. "): " } })
        if answers then
          local count = tonumber(answers[1]) or DEFAULT_REQUEST
          local result, err = connection.call("request", { item = row.item, count = count })
          if result then
            set_message(describe_request(result, count))
          else
            set_message(err, "error")
          end
        end
      end,
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
    load = function() return load_alert_history(connection) end,
    describe = describe_alert,
    role = alert_role,
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

  -- Storage --------------------------------------------------------------

  local function set_role(row, role)
    if row then
      local message = row.label .. " is now " .. role .. "."
      run("set_storage", { storage = row.handle, role = role }, message)
    end
  end

  local function set_label(row)
    local answers = ui.form("Label for " .. row.handle, { { label = "Label: " } })
    if answers then
      run("set_storage", { storage = row.handle, label = answers[1] }, "Label set.")
    end
  end

  local function storages_by_handle()
    local by_handle = {}
    for _, row in ipairs(connection.call("storages") or {}) do
      by_handle[row.handle] = row
    end
    return by_handle
  end

  -- Find a chest by dropping an item into it: whichever inventory's contents
  -- changed meanwhile is the one.
  local function find_chest()
    local before = storages_by_handle()
    if not ui.confirm("Drop any item into the chest, then choose yes.") then
      return
    end
    local changed = {}
    for handle, row in pairs(storages_by_handle()) do
      local old = before[handle]
      if old and old.total ~= row.total then
        changed[#changed + 1] = row
      end
    end
    if #changed == 0 then
      return set_message("No chest changed; is its modem switched on (red)?", "warn")
    end
    local row = changed[1]
    if #changed > 1 then
      local names = {}
      for index, candidate in ipairs(changed) do
        names[index] = candidate.label
      end
      row = changed[ui.menu({ title = "Several chests changed", items = names })]
    end
    local actions = { "Set label", "Storage", "Input", "Output", "Ignore", "Cancel" }
    local choice = ui.menu({ title = "Found " .. row.label, items = actions })
    if choice == 1 then
      set_label(row)
    elseif choice <= 5 then
      set_role(row, actions[choice]:lower())
    end
  end

  tabs[6] = {
    title = "Storage",
    load = function() return connection.call("storages") end,
    describe = function(row)
      return string.format("%-18s %-7s %s", row.label, row.role, describe_fill(row))
    end,
    role = function(row) return row.role == "ignore" and "faint" or nil end,
    hints = { { "m", "Map" }, { "f", "Find" }, { "l", "Label" }, { "s/i/o/x", "Role" } },
    keys = {
      m = function() show_map(connection) end,
      f = find_chest,
      l = set_label,
      s = function(row) set_role(row, "storage") end,
      i = function(row) set_role(row, "input") end,
      o = function(row) set_role(row, "output") end,
      x = function(row) set_role(row, "ignore") end,
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
-- stock rename
------------------------------------------------------------------------------

-- In a domain, refuse a name whose record already points at another computer.
local function check_name_is_free(domain, service_type)
  local service = domain.find_service(service_type)
  if service and service.id ~= os.getComputerID() then
    return nil, service_type .. " is already used by " .. tostring(service.host)
  end
  return true
end

-- Give this stock computer a new name (or none, with --clear). The service
-- registers the new record when it restarts; the old record is removed here.
local function rename(wanted)
  local server = blockos.stock_server
  if not server then
    fail("Run this on the stock computer itself (see 'stock setup').")
    return
  end
  if not (blockos.user and blockos.user.is_admin) then
    fail("Only administrators can rename a stock computer.")
    return
  end

  local new_name = nil
  if wanted ~= "--clear" then
    local err
    new_name, err = stock.check_name(wanted)
    if not new_name then
      fail(err)
      return
    end
  end
  local config = server.config
  if new_name == config.name then
    ui.print("The name is unchanged.", "warn")
    return
  end

  local old_type = stock_client.service_type(config.name)
  local new_type = stock_client.service_type(new_name)
  local found, domain = pcall(import, "domain")
  local is_joined = found and domain.is_joined()
  if is_joined then
    local ok, err = check_name_is_free(domain, new_type)
    if not ok then
      fail(err)
      return
    end
  end

  config.name = new_name
  local saved, save_error = server.monitor.save()
  if not saved then
    fail(save_error)
    return
  end
  if is_joined then
    local ok, err = domain.unregister_service(old_type)
    if not ok then
      ui.print("Could not remove the old " .. old_type .. " record: " .. tostring(err), "warn")
    end
  end
  -- Restarting re-registers under the new name (rednet.host and the domain record).
  blockos.services.restart("storage-monitor")

  ui.status("Now registered as " .. new_type .. ".", "ok")
  if new_name then
    ui.print("Other computers: 'stock --server " .. new_name .. "',", "dim")
    ui.print("or as default: 'set blockos.stock.server " .. new_name .. "'.", "dim")
  else
    ui.print("Other computers find it without --server again.", "dim")
  end
end

------------------------------------------------------------------------------

local REMOTE_COMMANDS = {
  status = true,
  alerts = true,
  access = true,
  sound = true,
  react = true,
  storage = true,
  request = true,
  map = true,
}

local options = parse_args()
local command = options.words[1]

if command == "setup" then
  setup(options)
elseif command == "rename" then
  if options.words[2] then
    rename(options.words[2])
  else
    print_usage()
  end
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
  elseif command == "map" then
    show_map(connection)
  elseif command == "storage" then
    change_storage(connection, options.words)
  elseif command == "request" then
    request_items(connection, options.words[2], options.words[3], options.words[4])
  elseif command == "react" then
    change_reactions(connection, options.words[2], options.words[3], options.words[4],
      options.words[5])
  else
    run_tool(connection)
  end
else
  print_usage()
end
