-- alerts-hub service: receives alerts from every computer (protocol "blockos.alerts") and
-- sends each to the channels that want it (see alerts, alerts_hub). One hub is enough
-- for the whole network; it registers the domain service record "alerts" and hosts its
-- rednet name for computers without a domain.
--
-- A failing channel is a problem of this computer (a notice with a level), so it goes
-- out as an alert through the other channels. In a domain the controller raises this
-- computer's problems (see dc_alerts); without one the hub raises them itself.

-- Queued when an alert waits to be sent, so the delivery loop wakes up.
local WAKE_EVENT = "blockos_alerts_queued"

local function run(ctx)
  local rpc = import("rpc")
  local fsx = import("fsx")
  local paths = import("paths")
  local notices = import("notices")
  local alerts = import("alerts")
  local alerts_hub = import("alerts_hub")

  local config_path = paths.top(alerts_hub.CONFIG_FILE)
  local config = fsx.read_table(config_path) or { channels = {} }
  local function save()
    local ok, err = pcall(fsx.write_table, config_path, config)
    if not ok then
      return nil, "could not save the channels: " .. tostring(err)
    end
    return true
  end

  local kinds = alerts_hub.load_kinds()
  local hub = alerts_hub.new({
    kinds = kinds,
    config = config,
    save = save,
    wake = function() os.queueEvent(WAKE_EVENT) end,
  })
  ctx.log.info("channel kinds: %s", table.concat(hub.kind_names(), ", "))

  local ok, err = import("discovery").advertise(alerts.SERVICE_TYPE, alerts.PROTOCOL)
  if not ok then
    ctx.log.warn("could not register the alerts service record: %s", tostring(err))
  end

  -- The welcome screen of the hub's computer says how many problems are open.
  local function update_notice()
    local count = #hub.active_list()
    if count == 0 then
      notices.clear("alerts")
    else
      notices.set("alerts", count .. " alert(s) active: type 'alerts'")
    end
  end

  local function listen()
    while true do
      local _, sender, message, protocol = os.pullEvent("rednet_message")
      if protocol == alerts.PROTOCOL then
        local result = alerts_hub.on_message(hub, sender, message)
        if result then
          update_notice()
        end
      end
    end
  end

  local function channel_problems()
    for name, status in pairs(hub.status) do
      if status.last_error and status.logged_error ~= status.last_error then
        ctx.log.warn("alert channel %s: %s", name, status.last_error)
        local text = "Alert channel " .. name .. " fails: " .. status.last_error
        notices.set("alerts:" .. name, text:sub(1, 100), "warn")
      elseif not status.last_error and status.logged_error then
        notices.clear("alerts:" .. name)
      end
      status.logged_error = status.last_error
    end
  end

  -- Without a domain nobody brokers this computer's problems: raise them here.
  local function own_problems()
    local found, domain = pcall(import, "domain")
    if found and domain.is_joined() then
      return
    end
    local tracker = alerts.problem_tracker(function(fields)
      hub.receive(assert(alerts.alert(fields)))
      update_notice()
    end)
    local host = blockos.net and blockos.net.hostname() or ("#" .. os.getComputerID())
    while true do
      tracker.update(host, notices.problems())
      os.pullEvent(notices.PROBLEMS_EVENT)
    end
  end

  local function deliver()
    while true do
      local wait = hub.deliver_due()
      channel_problems()
      if wait then
        local timer = os.startTimer(math.max(0.05, wait))
        repeat
          local event, value = os.pullEvent()
        -- a new alert may be for a channel that is due now
        until (event == "timer" and value == timer) or event == WAKE_EVENT
      else
        os.pullEvent(WAKE_EVENT)
      end
    end
  end

  local handlers = alerts_hub.handlers(hub)
  local raise = handlers.raise
  handlers.raise = function(request_ctx, args)
    local result, raise_error = raise(request_ctx, args)
    update_notice()
    return result, raise_error
  end

  parallel.waitForAll(
    function() rpc.serve(alerts.PROTOCOL, handlers) end,
    listen,
    deliver,
    own_problems
  )
end

return {
  name = "alerts-hub",
  description = "Sends alerts to Discord, webhooks, mail and computers",
  after = { "net", "domain-client" },
  restart = "on-failure",
  run = run,
}
