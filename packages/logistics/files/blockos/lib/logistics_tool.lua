--- The logistics tool's full-screen interface (tabs: Overview, Catalog, Alarms,
-- Alerts, Storage, Nodes, Crafting) and the formatting it shares with the `logistics`
-- command. Kept apart from bin/logistics.lua so the command stays argument
-- parsing and dispatch.
-- @module logistics_tool

local logistics = import("logistics")
local ui = import("ui")

local logistics_tool = {}

local function fail(message)
  ui.print(tostring(message), "error")
end

logistics_tool.NO_STORAGE_SHORT = "No storage found: right-click each wired modem"

logistics_tool.DEFAULT_REQUEST = 64

function logistics_tool.describe_fill(row)
  if not row.size then
    return "-"
  end
  return row.used .. "/" .. row.size .. " slots"
end

function logistics_tool.describe_request(result, count)
  local text = string.format("Moved %d of %d %s to %s.", result.moved, count,
    tostring(result.label), tostring(result.output))
  if result.node then
    text = text:sub(1, -2) .. " on " .. result.node .. "."
  end
  return text, result.moved < count and "warn" or "ok"
end

-- "12:04 LOW: Copper Ingot 0/1".
function logistics_tool.describe_alert(alert)
  local state = alert.is_low and "LOW" or "ok again"
  local time = alert.time and (alert.time .. " ") or ""
  return string.format("%s%s: %s %d/%d", time, state, alert.label or alert.item, alert.count,
    alert.limit)
end

-- Only the newest alert of an item is in colour; older ones are history.
function logistics_tool.alert_role(alert)
  if not alert.is_current then
    return "faint"
  end
  return alert.is_low and "error" or "ok"
end

function logistics_tool.load_alert_history(connection)
  local alerts, err = connection.call("alerts")
  return alerts and logistics.alert_history(alerts), err
end

-- Short local names inside the tool.
local NO_STORAGE_SHORT = logistics_tool.NO_STORAGE_SHORT
local DEFAULT_REQUEST = logistics_tool.DEFAULT_REQUEST
local describe_alert = logistics_tool.describe_alert
local alert_role = logistics_tool.alert_role
local load_alert_history = logistics_tool.load_alert_history
local describe_fill = logistics_tool.describe_fill
local describe_request = logistics_tool.describe_request

------------------------------------------------------------------------------
-- The tool
------------------------------------------------------------------------------

function logistics_tool.show_map(connection)
  local ok, err = import("logistics_map").run(connection)
  if not ok then
    fail(err)
  end
end

--- Run the full-screen tool until q is pressed.
-- @tparam table connection From logistics_client.connect.
function logistics_tool.run(connection)
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
  local ROWLESS_KEYS = { W = true, s = true, t = true, f = true, m = true }

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
        local side_menu = { title = "Side of " .. target.target, items = logistics.SIDES }
        local side = logistics.SIDES[ui.menu(side_menu)]
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

  -- Storage --------------------------------------------------------------

  -- node/handle: two nodes may have a chest of the same name.
  local function storage_ref(row)
    return row.node and (row.node .. "/" .. row.handle) or row.handle
  end

  local function set_role(row, role)
    if row then
      local message = row.label .. " is now " .. role .. "."
      run("set_storage", { storage = storage_ref(row), role = role }, message)
    end
  end

  local function set_label(row)
    local answers = ui.form("Label for " .. row.handle, { { label = "Label: " } })
    if answers then
      run("set_storage", { storage = storage_ref(row), label = answers[1] }, "Label set.")
    end
  end

  -- Find a chest by dropping an item into it: whichever block's contents
  -- changed meanwhile is the one. Sorting pauses meanwhile, so the input
  -- chest and its targets do not change on their own.
  local function find_chest()
    if not run("find_start", nil, nil) then
      return
    end
    local is_done = ui.confirm("Drop any item into the chest, then choose yes.")
    local changed = connection.call("find_finish") or {}
    if not is_done then
      return set_message(nil)
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
    local actions = { "Set label", "Storage", "Input", "Output", "Ignore", "Port", "Cancel" }
    local choice = ui.menu({ title = "Found " .. row.label, items = actions })
    if choice == 1 then
      set_label(row)
    elseif choice <= 6 then
      set_role(row, actions[choice]:lower())
    end
  end

  -- An output with a position is a depot: requests "near" a place go to the nearest.
  local function set_position(row)
    local answers = ui.form("Position of " .. row.label,
      { { label = "x y z (empty: here by GPS, - clears): " } })
    if not answers then
      return
    end
    local text = answers[1]
    local change = { storage = storage_ref(row) }
    if text == "-" then
      change.clear_pos = true
    elseif text == "" then
      local x, y, z = gps.locate(2)
      if not x then
        return set_message("No GPS fix here; type the position instead.", "warn")
      end
      change.pos = { x = x, y = y, z = z }
    else
      local x, y, z = text:match("^%s*(%-?%d+)[%s,]+(%-?%d+)[%s,]+(%-?%d+)%s*$")
      if not x then
        return set_message("Type three numbers: x y z.", "warn")
      end
      change.pos = { x = tonumber(x), y = tonumber(y), z = tonumber(z) }
    end
    run("set_storage", change, change.clear_pos and "Position removed." or "Position set.")
  end

  -- A configured chest that is gone (e.g. its modem was re-placed).
  local function forget(row)
    if row and row.is_missing and ui.confirm("Forget " .. row.label .. "?") then
      run("set_storage", { storage = storage_ref(row), forget = true },
        row.label .. " forgotten.")
    elseif row then
      set_message("Only missing chests can be forgotten.", "warn")
    end
  end

  tabs[5] = {
    title = "Storage",
    load = function() return connection.call("storages") end,
    describe = function(row)
      local fill = row.is_missing and "missing" or describe_fill(row)
      local depot = (row.role == "output" and row.pos) and " depot" or ""
      if row.port then
        depot = " " .. row.port
      end
      return string.format("%-10s %-16s %-7s %s%s", ui.fit(row.node or "", 10),
        ui.fit(row.label, 16), row.role, fill, depot)
    end,
    role = function(row) return row.role == "ignore" and "faint" or nil end,
    hints = { { "m", "Map" }, { "f", "Find" }, { "l", "Label" }, { "s/i/o/x/t", "Role" },
      { "p", "Position" }, { "d", "Forget" } },
    keys = {
      m = function() logistics_tool.show_map(connection) end,
      f = find_chest,
      l = set_label,
      p = set_position,
      s = function(row) set_role(row, "storage") end,
      i = function(row) set_role(row, "input") end,
      o = function(row) set_role(row, "output") end,
      x = function(row) set_role(row, "ignore") end,
      t = function(row) set_role(row, "port") end,
      d = forget,
    },
  }

  tabs[6] = {
    title = "Nodes",
    load = function() return connection.call("nodes") end,
    describe = function(row)
      local health = row.is_stale and "STALE" or "ok"
      return string.format("%-14s %3d chests %5d items %5ss %s", ui.fit(row.name, 14),
        row.blocks, row.items, tostring(row.age), health)
    end,
    role = function(row) return row.is_stale and "warn" or nil end,
    hints = { { "d", "Forget" } },
    keys = {
      d = function(row)
        if ui.confirm("Forget node " .. row.name .. "? (It comes back if it reports.)") then
          run("forget_node", { node = row.name }, row.name .. " forgotten.")
        end
      end,
    },
  }

  -- Crafting: jobs first, then what can be crafted.
  tabs[7] = {
    title = "Crafting",
    load = function()
      local recipes, err = connection.call("recipes")
      if not recipes then
        return nil, err
      end
      local rows = {}
      for _, job in ipairs(connection.call("jobs") or {}) do
        job.is_job = true
        rows[#rows + 1] = job
      end
      for _, recipe in ipairs(recipes) do
        rows[#rows + 1] = recipe
      end
      return rows
    end,
    describe = function(row)
      if row.is_job then
        return string.format("%-8s %-18s %d/%d %s", row.state, ui.fit(row.item, 18),
          row.made or 0, row.count or 0, row.note or "")
      end
      return string.format("%-20s %7d  on %s", ui.fit(row.label, 20), row.count, row.node)
    end,
    role = function(row)
      if row.is_job and row.state == "failed" then
        return "error"
      elseif row.is_job and row.state == "waiting" then
        return "warn"
      end
      return row.is_job and "dim" or nil
    end,
    hints = { { "c", "Craft" } },
    keys = {
      c = function(row)
        if row.is_job then
          return set_message("Pick an item below the jobs.", "warn")
        end
        local answers = ui.form("Craft " .. row.label, { { label = "How many: ", default = "1" } })
        if answers then
          local count = tonumber(answers[1]) or 1
          run("craft", { item = row.item, count = count },
            "Crafting " .. count .. " " .. row.label .. " on " .. row.node .. ".")
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
    ui.header(1, "Logistics " .. ui.GLYPHS.dot .. " " .. connection.describe,
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

return logistics_tool
