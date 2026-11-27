-- logistics: storage, requests, levels and alarms across the logistics nodes.
--
--   logistics                          full-screen tool (Overview, Catalog, Alarms,
--                                      Alerts, Storage, Nodes)
--   logistics status | alerts | nodes  print the current state
--   logistics storage [list]           every chest with its node, role and label
--   logistics storage role <chest> storage|input|output|ignore
--   logistics storage label <chest> <label...>   (nothing removes it)
--   logistics storage pos <chest> <x y z> | here | clear
--                                      an output with a position is a depot
--   logistics request <item> [count] [output | here]
--                                      deliver items to an output chest (here: the
--                                      nearest depot to this computer, by GPS)
--   logistics depots                   the depots, nearest first
--   logistics map                      the network map, with item moves animated
--   logistics board <peripheral> [wall|list|auto] | off
--                                      a board on a monitor or Display Link: the wall
--                                      (whole network, animated) on big monitors, else
--                                      the list of levels
--   logistics sound note|sound|file <value> [volume] | test
--                                      alarm sound: a note block instrument, a
--                                      Minecraft sound event, or a .dfpwm audio file
--   logistics react add <item> <target> <side> | remove <item> | list
--                                      on THIS computer: a redstone output that stays
--                                      on while the item is low (e.g. run a farm until
--                                      it is refilled); target is "computer" or a relay
--   logistics levels import <node>     move a node's lone-mode levels to the controller
--   logistics node forget <node>       drop a node that was taken down for good
--   logistics node private <node>      managed mode: only members of the role
--                                      logistics-node-<node> see that node's items
--   logistics node side <side>         on a node: which modem is the storage network
--   logistics craft [<item> [count]]  crafting: what can be made, jobs, start one
--                                      (logistics craft help: teaching and recipes)
--   logistics rename <name> | --clear  on the controller: register as logistics-<name>
--   --server <name>                    use the controller "logistics-<name>"
local args = { ... }
local ui = blockos.ui
local logistics = import("logistics")
local logistics_client = import("logistics_client")
local logistics_tool = import("logistics_tool")

-- Shared with the full-screen tool (lib/logistics_tool.lua).
local DEFAULT_REQUEST = logistics_tool.DEFAULT_REQUEST
local describe_alert = logistics_tool.describe_alert
local alert_role = logistics_tool.alert_role
local load_alert_history = logistics_tool.load_alert_history
local describe_fill = logistics_tool.describe_fill
local describe_request = logistics_tool.describe_request

local function print_usage()
  print("Usage: logistics [--server <name>]")
  print("       logistics status | alerts | nodes | depots | map")
  print("       logistics storage [list] | role <chest> <role> | label <chest> <label>")
  print("       logistics storage pos <chest> <x y z> | here | clear")
  print("       logistics request <item> [count] [output chest | here]")
  print("       logistics board <peripheral> [wall|list|auto] | off")
  print("       logistics sound note|sound|file <value> [volume] | test")
  print("       logistics react add <item> <target> <side> | remove <item> | list")
  print("       logistics levels import <node>")
  print("       logistics node forget|private <node> | side <side>")
  print("       logistics craft [<item> [count]] | craft help")
  print("       logistics rename <name> | rename --clear")
end

local function parse_args()
  local options = { words = {} }
  local i = 1
  while i <= #args do
    local flag = args[i]
    if flag == "--server" then
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

-- The two usual reasons a node sees no storage at all.
local function print_no_storage_hint()
  ui.print("No storage found. Right-click each wired modem so it turns red,", "warn")
  ui.print("and put it on the storage's interface block (multiblocks).", "warn")
end

local function connect(options)
  local connection, err = logistics_client.connect(options.server, { interactive = true })
  if not connection then
    fail(err)
  end
  return connection
end

------------------------------------------------------------------------------
-- Printing commands
------------------------------------------------------------------------------

local function show_status(connection)
  local data, err = connection.call("status")
  if not data then
    return fail(err)
  end
  ui.title((data.title or "Logistics") .. " (" .. connection.describe .. ")")
  ui.table({
    { title = "ITEM", key = "label" },
    { title = "COUNT", key = "count" },
    { title = "LIMIT", key = "limit" },
    { title = "STATE", key = function(row) return row.is_low and "LOW" or "ok" end },
  }, data.rows, function(row) return row.is_low and "error" or "text" end)
  if data.nodes == 0 then
    ui.print("No node has reported yet: install logistics-node next to the chests.", "warn")
  elseif data.sources == 0 then
    print_no_storage_hint()
  end
end

local function show_nodes(connection)
  local rows, err = connection.call("nodes")
  if not rows then
    return fail(err)
  end
  ui.title("Nodes (" .. connection.describe .. ")")
  ui.table({
    { title = "NODE", key = "name" },
    { title = "CHESTS", key = "blocks" },
    { title = "ITEMS", key = "items" },
    { title = "SEEN", key = function(row) return row.age .. "s ago" end },
  }, rows, function(row) return row.is_stale and "warn" or "text" end)
end

local function show_alerts(connection)
  local history, err = load_alert_history(connection)
  if not history then
    return fail(err)
  end
  ui.title("Recent level alerts (newest first)")
  if #history == 0 then
    ui.print("  (none)", "faint")
  end
  for _, alert in ipairs(history) do
    ui.status(describe_alert(alert), alert_role(alert))
  end
end

local BOARD_STYLES = { auto = true, wall = true, list = true }

local function set_board(name, style)
  if not (blockos.user and blockos.user.is_admin) then
    return fail("Only administrators can change the board.")
  end
  if name == "off" then
    blockos.config.set("blockos.logistics.board", nil)
    ui.print("Board turned off.", "ok")
    return
  end
  if not peripheral.isPresent(name) then
    return fail("No peripheral named " .. name)
  end
  if style and not BOARD_STYLES[style] then
    return print_usage()
  end
  blockos.config.set("blockos.logistics.board", name)
  if style then
    blockos.config.set("blockos.logistics.board_style", style)
  end
  ui.print("Board shown on " .. name .. ".", "ok")
  ui.print("A big monitor shows the wall (the whole network); 'list' for levels only.", "dim")
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

-- Find an item by its label or ID among the watched items.
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
  local reactions = blockos.config.get("blockos.logistics.reactions", {})
  ui.title("Reactions on this computer")
  ui.table({
    { title = "ITEM", key = "item" },
    { title = "OUTPUT", key = function(r) return r.target .. ":" .. r.side end },
  }, reactions)
end

-- logistics react add <item> <target> <side> | remove <item> | list
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
  for _, reaction in ipairs(blockos.config.get("blockos.logistics.reactions", {})) do
    if reaction.item ~= row.item then
      kept[#kept + 1] = reaction
    end
  end
  if action == "add" then
    local ok, output_error = logistics.validate_output({ target = target, side = side })
    if not ok then
      return fail(output_error)
    end
    kept[#kept + 1] = { item = row.item, target = target, side = side }
  elseif action ~= "remove" then
    return print_usage()
  end
  blockos.config.set("blockos.logistics.reactions", kept)
  ui.print("Reactions updated.", "ok")
  show_reactions()
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
    { title = "NODE", key = "node" },
    { title = "CHEST", key = "label" },
    { title = "ROLE", key = "role" },
    { title = "FILL", key = describe_storage_fill },
    { title = "NAME", key = "handle" },
  }, rows, function(row) return row.role == "ignore" and "faint" or "text" end)
end

-- This computer's position by GPS (pocket computers and turtles next to a chest).
local function here()
  local x, y, z = gps.locate(2)
  if not x then
    return nil, "No GPS fix: are GPS hosts in range of a wireless modem?"
  end
  return { x = x, y = y, z = z }
end

-- pos <chest> x y z | here | clear
local function position_args(call_args, words)
  if words[4] == "clear" then
    call_args.clear_pos = true
  elseif words[4] == "here" then
    local pos, err = here()
    if not pos then
      return nil, err
    end
    call_args.pos = pos
  else
    call_args.pos = { x = tonumber(words[4]), y = tonumber(words[5]), z = tonumber(words[6]) }
  end
  return call_args
end

local STORAGE_ACTIONS = { role = true, label = true, pos = true }

local function change_storage(connection, words)
  local action, chest = words[2], words[3]
  if action == nil or action == "list" then
    return show_storages(connection)
  end
  if not chest or not STORAGE_ACTIONS[action] then
    return print_usage()
  end
  local call_args = { storage = chest }
  if action == "role" then
    call_args.role = words[4]
  elseif action == "label" then
    call_args.label = table.concat(words, " ", 4)
  else
    local ok, err = position_args(call_args, words)
    if not ok then
      return fail(err)
    end
  end
  local result, err = connection.call("set_storage", call_args)
  if not result then
    return fail(err)
  end
  ui.print("Changed " .. result.storage .. " on " .. tostring(result.node) .. ".", "ok")
end

-- The output may be "here": the nearest depot to this computer.
local function request_items(connection, item, count_text, output)
  if not item then
    return print_usage()
  end
  local count = tonumber(count_text) or DEFAULT_REQUEST
  local call_args = { item = item, count = count, output = output }
  if output == "here" then
    local pos, err = here()
    if not pos then
      return fail(err)
    end
    call_args.output, call_args.near = nil, pos
  end
  local result, err = connection.call("request", call_args)
  if not result then
    return fail(err)
  end
  ui.print(describe_request(result, count))
  if result.pos then
    ui.print("At " .. result.pos.x .. " " .. result.pos.y .. " " .. result.pos.z .. ".", "dim")
  end
end

local function show_depots(connection)
  local pos = here()
  local depots, err = connection.call("depots", { near = pos })
  if not depots then
    return fail(err)
  end
  ui.title("Depots (" .. connection.describe .. ")")
  ui.table({
    { title = "DEPOT", key = "label" },
    { title = "NODE", key = "node" },
    { title = "AT", key = function(row)
      return row.pos.x .. " " .. row.pos.y .. " " .. row.pos.z
    end },
    { title = "AWAY", key = function(row)
      return row.distance and (math.floor(row.distance) .. "m") or "-"
    end },
  }, depots)
  if #depots == 0 then
    ui.print("No depots yet: 'logistics storage pos <output chest> here'.", "dim")
  end
end

------------------------------------------------------------------------------
-- Levels and nodes
------------------------------------------------------------------------------

local function import_levels(connection, node)
  if not node then
    return print_usage()
  end
  local result, err = connection.call("import_levels", { node = node })
  if not result then
    return fail(err)
  end
  ui.print("Took over " .. result.added .. " levels from " .. node .. ".", "ok")
  ui.print("Alarm outputs stay behind (they used the node's sides): set them again", "dim")
  ui.print("in the Alarms tab.", "dim")
end

-- Managed mode: a role for one node, so it can be kept to some players.
local function make_private(node)
  local found, roles = pcall(import, "roles")
  if not found or not import("domain").is_joined() then
    return fail("Private nodes need a domain (everything is open without one).")
  end
  local role = logistics.NODE_ROLE_PREFIX .. node
  local ok, err = roles.create(role, logistics.ADMINS, true)
  if not ok then
    return fail(err)
  end
  ui.print("Created " .. role .. " (still open to everyone).", "ok")
  ui.print("To keep it to some players: 'domain group everyone " .. role .. " off',", "dim")
  ui.print("then 'domain group addmember " .. role .. " <user>' (or in dsa).", "dim")
end

local function change_node(connection, action, value)
  if action == "forget" and value then
    local ok, err = connection.call("forget_node", { node = value })
    if not ok then
      return fail(err)
    end
    return ui.print("Forgot node " .. value .. ".", "ok")
  elseif action == "private" and value then
    return make_private(value)
  end
  print_usage()
end

-- On a node: which modem is the storage network (closed for rednet).
local function set_node_side(side)
  local node = blockos.logistics_node
  if not node then
    return fail("Run this on a logistics node (package logistics-node).")
  end
  if not (blockos.user and blockos.user.is_admin) then
    return fail("Only administrators can change the storage modem.")
  end
  if not side or not peripheral.hasType(side, "modem") then
    return fail("No modem on side " .. tostring(side) .. ".")
  end
  local net = import("net")
  local old = node.config.storage_side
  if old and old ~= side and not node.config.is_shared then
    net.close_side(old, true)
  end
  node.config.storage_side = side
  node.config.is_shared = nil
  node.save()
  net.close_side(side)
  blockos.services.restart("logistics-node")
  ui.print("The storage network is on " .. side .. " (closed for rednet).", "ok")
end

------------------------------------------------------------------------------
-- logistics rename
------------------------------------------------------------------------------

-- In a domain, refuse a name whose record already points at another computer.
local function check_name_is_free(domain, service_type)
  local service = domain.find_service(service_type)
  if service and service.id ~= os.getComputerID() then
    return nil, service_type .. " is already used by " .. tostring(service.host)
  end
  return true
end

-- Give the controller a new name (or none, with --clear). The service registers the
-- new record when it restarts; the old record is removed here.
local function rename(wanted)
  local hub = blockos.logistics_hub
  if not (hub and blockos.services.state("logistics-controller") == "running") then
    fail("Run this on the logistics controller itself.")
    return
  end
  if not (blockos.user and blockos.user.is_admin) then
    fail("Only administrators can rename the controller.")
    return
  end

  local new_name = nil
  if wanted ~= "--clear" then
    local err
    new_name, err = logistics.check_name(wanted)
    if not new_name then
      fail(err)
      return
    end
  end
  local config = hub.config
  if new_name == config.name then
    ui.print("The name is unchanged.", "warn")
    return
  end

  local old_type = logistics_client.service_type(config.name)
  local new_type = logistics_client.service_type(new_name)
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
  local saved, save_error = hub.hub.save()
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
  blockos.services.restart("logistics-controller")

  ui.status("Now registered as " .. new_type .. ".", "ok")
  if new_name then
    ui.print("Other computers: 'logistics --server " .. new_name .. "',", "dim")
    ui.print("or as default: 'set blockos.logistics.server " .. new_name .. "'.", "dim")
  else
    ui.print("Other computers find it without --server again.", "dim")
  end
end

------------------------------------------------------------------------------

local REMOTE_COMMANDS = {
  status = true,
  alerts = true,
  nodes = true,
  depots = true,
  sound = true,
  react = true,
  storage = true,
  request = true,
  map = true,
  levels = true,
  node = true,
}

local options = parse_args()
local command = options.words[1]

if command == "rename" then
  if options.words[2] then
    rename(options.words[2])
  else
    print_usage()
  end
elseif command == "board" then
  if options.words[2] then
    set_board(options.words[2], options.words[3])
  else
    print_usage()
  end
elseif command == "node" and options.words[2] == "side" then
  set_node_side(options.words[3])
elseif command == "craft" then
  import("logistics_craft_cli").run(options.words, function() return connect(options) end)
elseif command == nil or REMOTE_COMMANDS[command] then
  local connection = connect(options)
  if not connection then
    return
  end
  if command == "status" then
    show_status(connection)
  elseif command == "alerts" then
    show_alerts(connection)
  elseif command == "nodes" then
    show_nodes(connection)
  elseif command == "depots" then
    show_depots(connection)
  elseif command == "sound" then
    set_sound(connection, options.words[2], options.words[3], options.words[4])
  elseif command == "map" then
    logistics_tool.show_map(connection)
  elseif command == "storage" then
    change_storage(connection, options.words)
  elseif command == "request" then
    request_items(connection, options.words[2], options.words[3], options.words[4])
  elseif command == "react" then
    change_reactions(connection, options.words[2], options.words[3], options.words[4],
      options.words[5])
  elseif command == "levels" and options.words[2] == "import" then
    import_levels(connection, options.words[3])
  elseif command == "node" then
    change_node(connection, options.words[2], options.words[3])
  elseif command == nil then
    logistics_tool.run(connection)
  else
    print_usage()
  end
else
  print_usage()
end
