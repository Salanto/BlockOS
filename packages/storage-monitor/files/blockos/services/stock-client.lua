-- stock-client service: on every computer with the storage-monitor package.
--
-- * Receives stock alerts from stock computers (only computers on a stock
--   computer's access list get them) and keeps the last few in memory.
-- * Puts a notice on the welcome screen while items are low.
-- * Draws a stock board on a monitor or Create Display Link when the
--   `blockos.stock.board` setting names one (set with `stock board <name>`).
-- * Reactions: redstone outputs that stay on while an item is low, e.g. to run
--   a farm until stock is refilled (`stock react ...`).

local MAX_ALERTS = 20
local REFRESH_SECONDS = 10

local function run(ctx)
  local config = ctx.config
  local stock = import("stock")
  local stock_alarms = import("stock_alarms")
  local stock_board = import("stock_board")
  local stock_client = import("stock_client")
  local wire = import("wire")

  local low_items = {} -- [server .. "/" .. item] = alert, while low
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

  local function remember(alert)
    local alerts = blockos.stock_alerts
    alerts[#alerts + 1] = alert
    if #alerts > MAX_ALERTS then
      table.remove(alerts, 1)
    end
    local key = alert.server .. "/" .. alert.item
    low_items[key] = alert.is_low and alert or nil
    update_notice()
    os.queueEvent("blockos_notice", "stock", alert)
  end

  -- Returns the alert if the message is one.
  local function on_message(message)
    local event = wire.parse(message, "event", stock_alarms.ALERT_SCHEMA)
    if event and event.topic == stock_alarms.ALERT_TOPIC then
      remember(event.data)
      return event.data
    end
    return nil
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
      remember(alerts[index])
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
    local connection = stock_client.connect(config.get("blockos.stock.server"))
    if not connection then
      return
    end
    local data, err = connection.call("status")
    if not data then
      ctx.log.warn("stock status: %s", tostring(err))
      return
    end
    -- Replace, not merge: an item no longer in the status (unwatched) is not low.
    local fresh = {}
    for _, row in ipairs(data.rows) do
      fresh[row.item] = row.is_low
    end
    item_low = fresh
    apply_reactions()
    draw_board(data)
  end

  local function on_alert_message(message)
    local alert = on_message(message)
    if alert then
      item_low[alert.item] = alert.is_low
      apply_reactions()
    end
  end

  local timer = os.startTimer(1)
  while true do
    local event, a, b, c = os.pullEvent()
    if event == "rednet_message" and c == stock_alarms.ALERT_PROTOCOL then
      on_alert_message(b)
    elseif event == "timer" and a == timer then
      check_local_alerts()
      refresh()
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
