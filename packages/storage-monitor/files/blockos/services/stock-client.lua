-- stock-client service: on every computer with the storage-monitor package.
--
-- * Receives stock alerts from stock computers (only computers on a stock
--   computer's access list get them) and keeps the last few in memory.
-- * Puts a notice on the welcome screen while items are low.
-- * Draws a stock board on a monitor or Create Display Link when the
--   `blockos.stock.board` setting names one (set with `stock board <name>`).

local MAX_ALERTS = 20
local BOARD_SECONDS = 10

local function run(ctx)
  local config = ctx.config
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

  local function on_message(message)
    local event = wire.parse(message, "event", stock_alarms.ALERT_SCHEMA)
    if event and event.topic == stock_alarms.ALERT_TOPIC then
      remember(event.data)
    end
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

  local page = 1
  local function draw_board()
    local board = config.get("blockos.stock.board")
    if not board or board == "" then
      return
    end
    local connection = stock_client.connect(config.get("blockos.stock.server"))
    if not connection then
      return
    end
    local data, err = connection.call("status")
    if not data then
      ctx.log.warn("board: %s", tostring(err))
      return
    end
    local pages = stock_board.show(peripheral, board, data, page)
    page = (pages and page < pages) and (page + 1) or 1
  end

  local timer = os.startTimer(1)
  while true do
    local event, a, b, c = os.pullEvent()
    if event == "rednet_message" and c == stock_alarms.ALERT_PROTOCOL then
      on_message(b)
    elseif event == "timer" and a == timer then
      check_local_alerts()
      draw_board()
      timer = os.startTimer(BOARD_SECONDS)
    end
  end
end

return {
  name = "stock-client",
  description = "Stock alerts, welcome notices and stock boards",
  after = { "net", "domain-client", "storage-monitor" },
  restart = "on-failure",
  run = run,
}
