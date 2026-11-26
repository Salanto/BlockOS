-- stock-client service: on every computer with the storage-monitor package.
--
-- * Receives stock alerts from stock computers (only computers on a stock
--   computer's access list get them) and keeps the last few in memory.
-- * Puts a notice on the welcome screen while items are low.
-- * Draws a stock board on a monitor or Create Display Link when the
--   `blockos.stock.board` setting names one (set with `stock board <name>`).
-- * Reactions: redstone outputs that stay on while an item is low, e.g. to run
--   a farm until stock is refilled (`stock react ...`).
--
-- Nothing here trusts an alert forever: the notice is checked against each
-- stock computer's status, and reactions switch off when the stock computer
-- stops answering (a farm should not run on without anyone counting).

local MAX_ALERTS = 20
local REFRESH_SECONDS = 10
-- Refreshes without an answer before a stock computer counts as gone (~30s).
local MAX_MISSES = 3

local function run(ctx)
  local config = ctx.config
  local rpc = import("rpc")
  local stock = import("stock")
  local stock_alarms = import("stock_alarms")
  local stock_board = import("stock_board")
  local stock_client = import("stock_client")
  local wire = import("wire")

  -- [server .. "/" .. item] = { alert, id }, while low; id is the computer
  -- that sent the alert, so the notice can be checked with it later.
  local low_items = {}
  blockos.stock_alerts = blockos.stock_alerts or {}

  local function update_notice()
    local count = 0
    for _ in pairs(low_items) do
      count = count + 1
    end
    if blockos.notices then
      blockos.notices.stock = count > 0 and (count .. " item(s) low on stock (see 'stock')") or nil
    end
  end

  local function remember(alert, sender)
    local alerts = blockos.stock_alerts
    alerts[#alerts + 1] = alert
    if #alerts > MAX_ALERTS then
      table.remove(alerts, 1)
    end
    local key = alert.server .. "/" .. alert.item
    low_items[key] = alert.is_low and { alert = alert, id = sender } or nil
    update_notice()
    os.queueEvent("blockos_notice", "stock", alert)
  end

  -- Returns the alert if the message is one.
  local function on_message(sender, message)
    local event = wire.parse(message, "event", stock_alarms.ALERT_SCHEMA)
    if event and event.topic == stock_alarms.ALERT_TOPIC then
      remember(event.data, sender)
      return event.data
    end
    return nil
  end

  -- The status rows of the stock computer with this ID.
  local function status_rows(id)
    if id == os.getComputerID() then
      local server = blockos.stock_server
      if not server then
        return nil, "the storage-monitor service is not running"
      end
      return server.monitor.snapshot().rows
    end
    local data, err = rpc.call(id, stock_client.PROTOCOL, "status", nil, { retries = 0 })
    return data and data.rows, err
  end

  local function forget_server(server, still_low)
    for key, entry in pairs(low_items) do
      if entry.alert.server == server and not (still_low and still_low[entry.alert.item]) then
        low_items[key] = nil
      end
    end
  end

  -- Check the notice with each stock computer that has an item low. Clears
  -- items that recovered without an alert reaching us, and every item of a
  -- stock computer that refuses us (no longer on its access list) or is gone.
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

  -- On the stock computer itself, its own alerts are read directly.
  local seen_local = 0
  local function check_local_alerts()
    local server = blockos.stock_server
    if not server then
      return
    end
    local alerts = server.monitor.alerts
    if #alerts < seen_local then
      seen_local = 0
    end
    for index = seen_local + 1, #alerts do
      remember(alerts[index], os.getComputerID())
    end
    seen_local = #alerts
  end

  -- Reactions: redstone outputs that are on while an item is low (e.g. run an
  -- iron farm until iron is refilled). They follow the stock computer's actual
  -- state, polled every few seconds; alerts only make them react sooner, so a
  -- missed alert (this computer was unloaded) is corrected on the next poll.
  local item_low = {} -- [item] = true/false, from status and alerts
  local applied_reactions = {}

  local function apply_reactions()
    local reactions = config.get("blockos.stock.reactions", {})
    local wanted = stock.reaction_outputs(reactions, item_low)
    applied_reactions = stock_alarms.apply_redstone(wanted, applied_reactions)
  end

  local page = 1
  local shown_board = nil -- the peripheral the board was last drawn on
  local function draw_board(data)
    local board = config.get("blockos.stock.board")
    if not board or board == "" then
      return
    end
    local pages = stock_board.show(peripheral, board, data, page)
    page = (pages and page < pages) and (page + 1) or 1
    shown_board = board
  end

  -- A board turned off or moved would otherwise keep its last picture forever.
  local function clear_old_board(board)
    if shown_board and shown_board ~= board then
      pcall(stock_board.clear, peripheral, shown_board)
      shown_board = nil
    end
  end

  -- No contact for a while: switch reactions off instead of leaving them as
  -- they were (a farm would otherwise run on, or never start, unnoticed).
  local status_misses = 0
  local function on_status_failed(err)
    status_misses = status_misses + 1
    if status_misses == MAX_MISSES then
      ctx.log.warn("stock computer unreachable (%s); reactions off", tostring(err))
      item_low = {}
      apply_reactions()
    end
  end

  -- One status request feeds both the board and the reactions.
  local function refresh()
    local board = config.get("blockos.stock.board") or ""
    clear_old_board(board ~= "" and board or nil)
    local has_board = board ~= ""
    local has_reactions = #config.get("blockos.stock.reactions", {}) > 0
    if not has_reactions then
      -- Switches off outputs of reactions that were just removed.
      apply_reactions()
    end
    if not has_board and not has_reactions then
      return
    end
    local connection, connect_error = stock_client.connect(config.get("blockos.stock.server"))
    if not connection then
      on_status_failed(connect_error)
      return
    end
    local data, err = connection.call("status")
    if not data then
      ctx.log.warn("stock status: %s", tostring(err))
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
    draw_board(data)
  end

  local function on_alert_message(sender, message)
    local alert = on_message(sender, message)
    if alert then
      item_low[alert.item] = alert.is_low
      apply_reactions()
    end
  end

  local timer = os.startTimer(1)
  while true do
    local event, a, b, c = os.pullEvent()
    if event == "rednet_message" and c == stock_alarms.ALERT_PROTOCOL then
      on_alert_message(a, b)
    elseif event == "timer" and a == timer then
      check_local_alerts()
      refresh()
      check_notice()
      timer = os.startTimer(REFRESH_SECONDS)
    end
  end
end

return {
  name = "stock-client",
  description = "Stock alerts, notices, boards and reactions",
  after = { "net", "domain-client", "storage-monitor" },
  restart = "on-failure",
  run = run,
}
