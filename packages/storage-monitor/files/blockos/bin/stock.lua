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
local stock_tool = import("stock_tool")

-- Shared with the full-screen tool (lib/stock_tool.lua).
local ACCESS_LISTS = stock_tool.ACCESS_LISTS
local DEFAULT_REQUEST = stock_tool.DEFAULT_REQUEST
local describe_alert = stock_tool.describe_alert
local alert_role = stock_tool.alert_role
local load_alert_history = stock_tool.load_alert_history
local describe_fill = stock_tool.describe_fill
local describe_request = stock_tool.describe_request

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

local function describe_storage_fill(row)
  return row.is_missing and "missing" or describe_fill(row)
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
    { title = "FILL", key = describe_storage_fill },
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
    stock_tool.show_map(connection)
  elseif command == "storage" then
    change_storage(connection, options.words)
  elseif command == "request" then
    request_items(connection, options.words[2], options.words[3], options.words[4])
  elseif command == "react" then
    change_reactions(connection, options.words[2], options.words[3], options.words[4],
      options.words[5])
  else
    stock_tool.run(connection)
  end
else
  print_usage()
end
