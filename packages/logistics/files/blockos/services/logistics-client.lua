-- logistics-client service: on every computer with the logistics package.
--
-- * Receives level alerts from the hub (controller or lone node) and keeps the last
--   few in memory.
-- * Puts a notice on the welcome screen while items are low.
-- * Draws a board on a monitor or Create Display Link when the
--   `blockos.logistics.board` setting names one (`logistics board <name>`): the wall
--   (the whole network, animated) on a big monitor, else the list of levels.
-- * Reactions: redstone outputs that stay on while an item is low, e.g. to run
--   a farm until it is refilled (`logistics react ...`).
--
-- Nothing here trusts an alert forever: the notice is checked against the hub's
-- status, and reactions switch off when the hub stops answering (a farm should not
-- run on without anyone counting).

local MAX_ALERTS = 20
local REFRESH_SECONDS = 10
-- The wall's animation frames and how often it asks for new moves.
local FRAME_SECONDS = 0.3
local MOVES_SECONDS = 1
-- Refreshes without an answer before a hub counts as gone (~30s).
local MAX_MISSES = 3

-- Settings of the storage-monitor package, copied once to their new names.
local OLD_SETTINGS = {
  ["blockos.stock.server"] = "blockos.logistics.server",
  ["blockos.stock.board"] = "blockos.logistics.board",
  ["blockos.stock.reactions"] = "blockos.logistics.reactions",
}

local function migrate_settings()
  for old, new in pairs(OLD_SETTINGS) do
    local value = settings.get(old)
    if value ~= nil and settings.get(new) == nil then
      settings.set(new, value)
    end
    settings.unset(old)
  end
  settings.save()
end

local function run(ctx)
  local config = ctx.config
  local rpc = import("rpc")
  local logistics = import("logistics")
  local logistics_alarms = import("logistics_alarms")
  local logistics_board = import("logistics_board")
  local logistics_client = import("logistics_client")
  local logistics_wall = import("logistics_wall")
  local wire = import("wire")
  migrate_settings()

  -- [server .. "/" .. item] = { alert, id }, while low; id is the computer
  -- that sent the alert, so the notice can be checked with it later.
  local low_items = {}
  blockos.logistics_alerts = blockos.logistics_alerts or {}

  local function update_notice()
    local count = 0
    for _ in pairs(low_items) do
      count = count + 1
    end
    if blockos.notices then
      blockos.notices.logistics = count > 0 and (count .. " item(s) low (see 'logistics')") or nil
    end
  end

  local function remember(alert, sender)
    local alerts = blockos.logistics_alerts
    alerts[#alerts + 1] = alert
    if #alerts > MAX_ALERTS then
      table.remove(alerts, 1)
    end
    local key = alert.server .. "/" .. alert.item
    low_items[key] = alert.is_low and { alert = alert, id = sender } or nil
    update_notice()
    os.queueEvent("blockos_notice", "logistics", alert)
  end

  -- Returns the alert if the message is one.
  local function on_message(sender, message)
    local event = wire.parse(message, "event", logistics_alarms.ALERT_SCHEMA)
    if event and event.topic == logistics_alarms.ALERT_TOPIC then
      remember(event.data, sender)
      return event.data
    end
    return nil
  end

  -- The status rows of the hub with this ID.
  local function status_rows(id)
    if id == os.getComputerID() then
      local local_hub = blockos.logistics_hub
      if not local_hub then
        return nil, "no hub runs here any more"
      end
      return local_hub.hub.snapshot().rows
    end
    local data, err = rpc.call(id, logistics_client.PROTOCOL, "status", nil, { retries = 0 })
    return data and data.rows, err
  end

  local function forget_server(server, still_low)
    for key, entry in pairs(low_items) do
      if entry.alert.server == server and not (still_low and still_low[entry.alert.item]) then
        low_items[key] = nil
      end
    end
  end

  -- Check the notice with each hub that has an item low. Clears items that
  -- recovered without an alert reaching us, and every item of a hub that refuses us
  -- or is gone.
  local notice_misses = {} -- [server] = refreshes without an answer
  local function check_notice()
    local servers = {}
    for _, entry in pairs(low_items) do
      servers[entry.alert.server] = entry.id
    end
    for server, id in pairs(servers) do
      local rows, err = status_rows(id)
      if rows then
        notice_misses[server] = nil
        local still_low = {}
        for _, row in ipairs(rows) do
          still_low[row.item] = row.is_low or nil
        end
        forget_server(server, still_low)
      elseif not tostring(err):find("no answer") then
        forget_server(server, nil)
      else
        notice_misses[server] = (notice_misses[server] or 0) + 1
        if notice_misses[server] >= MAX_MISSES then
          notice_misses[server] = nil
          forget_server(server, nil)
        end
      end
    end
    update_notice()
  end

  -- On the hub itself, its own alerts are read directly (broadcasts do not reach
  -- the sender).
  local seen_local = 0
  local function check_local_alerts()
    local local_hub = blockos.logistics_hub
    if not local_hub then
      return
    end
    local alerts = local_hub.hub.alerts
    if #alerts < seen_local then
      seen_local = 0
    end
    for index = seen_local + 1, #alerts do
      remember(alerts[index], os.getComputerID())
    end
    seen_local = #alerts
  end

  -- Reactions: redstone outputs that are on while an item is low (e.g. run an
  -- iron farm until iron is refilled). They follow the hub's actual
  -- state, polled every few seconds; alerts only make them react sooner, so a
  -- missed alert (this computer was unloaded) is corrected on the next poll.
  local item_low = {} -- [item] = true/false, from status and alerts
  local applied_reactions = {}

  local function apply_reactions()
    local reactions = config.get("blockos.logistics.reactions", {})
    local wanted = logistics.reaction_outputs(reactions, item_low)
    applied_reactions = logistics_alarms.apply_redstone(wanted, applied_reactions)
  end

  local page = 1
  local shown_board = nil -- the peripheral the board was last drawn on
  local wall = nil -- { name, live, seq, log } while a wall is shown

  -- The wall on a big monitor (unless the list was asked for), else nil.
  local function wall_for(board)
    local style = config.get("blockos.logistics.board_style", "auto")
    if style == "list" or not peripheral.hasType(board, logistics_board.MONITOR_TYPE) then
      return nil
    end
    if wall and wall.name == board then
      return wall
    end
    local monitor = peripheral.wrap(board)
    if not logistics_wall.fit_scale(monitor) then
      return nil
    end
    wall = { name = board, live = logistics_wall.live(monitor) }
    return wall
  end

  -- What the wall needs besides the status: nodes, chests, item counts, alerts.
  local function load_wall(connection, data)
    local nodes = connection.call("nodes") or {}
    logistics_wall.add_totals(nodes, connection.call("catalog"))
    data.nodes = nodes
    data.storages = connection.call("storages") or {}
    data.alerts = connection.call("alerts") or {}
    wall.live.set_data(data)
    wall.connection = connection
  end

  local function draw_board(connection, data)
    local board = config.get("blockos.logistics.board")
    if not board or board == "" then
      return
    end
    shown_board = board
    if wall_for(board) then
      load_wall(connection, data)
      wall.live.frame()
      return
    end
    wall = nil
    local pages = logistics_board.show(peripheral, board, data, page)
    page = (pages and page < pages) and (page + 1) or 1
  end

  -- New moves for the wall's animation (the first call only learns where the log is).
  local function poll_wall_moves()
    if not (wall and wall.connection) then
      return
    end
    local result = wall.connection.call("moves", { since = wall.seq })
    if not result then
      return
    end
    if result.log == wall.log and wall.seq then
      wall.live.add_moves(result.moves)
    end
    wall.log, wall.seq = result.log, result.seq
  end

  -- A board turned off or moved would otherwise keep its last picture forever.
  local function clear_old_board(board)
    if shown_board and shown_board ~= board then
      pcall(logistics_board.clear, peripheral, shown_board)
      shown_board = nil
      wall = nil
    end
  end

  -- No contact for a while: switch reactions off instead of leaving them as
  -- they were (a farm would otherwise run on, or never start, unnoticed).
  local status_misses = 0
  local function on_status_failed(err)
    status_misses = status_misses + 1
    if status_misses == MAX_MISSES then
      ctx.log.warn("logistics hub unreachable (%s); reactions off", tostring(err))
      item_low = {}
      apply_reactions()
    end
  end

  -- One status request feeds both the board and the reactions.
  local function refresh()
    local board = config.get("blockos.logistics.board") or ""
    clear_old_board(board ~= "" and board or nil)
    local has_board = board ~= ""
    local has_reactions = #config.get("blockos.logistics.reactions", {}) > 0
    if not has_reactions then
      -- Switches off outputs of reactions that were just removed.
      apply_reactions()
    end
    if not has_board and not has_reactions then
      return
    end
    local server = config.get("blockos.logistics.server")
    local connection, connect_error = logistics_client.connect(server)
    if not connection then
      on_status_failed(connect_error)
      return
    end
    local data, err = connection.call("status")
    if not data then
      ctx.log.warn("logistics status: %s", tostring(err))
      on_status_failed(err)
      return
    end
    status_misses = 0
    -- Replace, not merge: an item no longer in the status (unwatched) is not low.
    local fresh = {}
    for _, row in ipairs(data.rows) do
      fresh[row.item] = row.is_low
    end
    item_low = fresh
    apply_reactions()
    draw_board(connection, data)
  end

  local function on_alert_message(sender, message)
    local alert = on_message(sender, message)
    if alert then
      item_low[alert.item] = alert.is_low
      apply_reactions()
    end
  end

  local timer = os.startTimer(1)
  local frame_timer = os.startTimer(FRAME_SECONDS)
  local next_moves = 0
  while true do
    local event, a, b, c = os.pullEvent()
    if event == "rednet_message" and c == logistics_alarms.ALERT_PROTOCOL then
      on_alert_message(a, b)
    elseif event == "timer" and a == timer then
      check_local_alerts()
      refresh()
      check_notice()
      timer = os.startTimer(REFRESH_SECONDS)
    elseif event == "timer" and a == frame_timer then
      -- Frames only while a wall is shown; otherwise check back now and then.
      if wall then
        if os.clock() >= next_moves then
          poll_wall_moves()
          next_moves = os.clock() + MOVES_SECONDS
        end
        if wall.live.frame() then
          frame_timer = os.startTimer(FRAME_SECONDS)
        else
          frame_timer = os.startTimer(MOVES_SECONDS)
        end
      else
        frame_timer = os.startTimer(REFRESH_SECONDS)
      end
    end
  end
end

return {
  name = "logistics-client",
  description = "Level alerts, notices, boards and reactions",
  after = { "net", "domain-client", "logistics-node", "logistics-controller" },
  restart = "on-failure",
  run = run,
}
