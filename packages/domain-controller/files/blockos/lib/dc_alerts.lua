--- The domain controller as an alert broker: joined computers report their problems
-- (notices.problems, in the status report they send anyway), and the controller raises
-- them with the alert hub and resolves them when they are gone. Computers need neither
-- the alerts package nor to find the hub themselves.
--
-- It also raises the controller's own problems (a nearly full disk), and an info alert
-- when a computer stops reporting (often only an unloaded chunk, so channels only hear
-- of it when they take info alerts).
-- @module dc_alerts

local alerts = import("alerts")

local dc_alerts = {}

--- A computer that has not reported for this long has stopped (3 missed reports at
-- the default 5 min interval, plus some slack).
dc_alerts.OFFLINE_SECONDS = 960

--- Create a broker.
-- @tparam function raise function(fields), e.g. an alerts.sender's raise
-- @treturn table broker
function dc_alerts.new(raise)
  local tracker = alerts.problem_tracker(raise)
  local broker = { offline = {} } -- [hostname] = true while it does not report

  local function offline_key(hostname)
    return hostname .. "/offline"
  end

  --- A computer sent a status report (dc_handlers hook).
  -- @tparam string hostname
  -- @tparam table report The host_update args ({ problems? }).
  function broker.on_report(hostname, report)
    if broker.offline[hostname] then
      broker.offline[hostname] = nil
      raise({ source = alerts.SYSTEM, key = offline_key(hostname), level = alerts.OK,
        title = hostname .. " reports again", host = hostname })
    end
    -- Older computers send no problems: nothing to compare, so nothing changes.
    if report.problems then
      tracker.update(hostname, report.problems)
    end
  end

  --- The controller's own problems.
  -- @tparam string hostname The controller's name.
  -- @tparam table problems notices.problems()
  function broker.own_problems(hostname, problems)
    tracker.update(hostname, problems)
  end

  --- Raise an info alert for computers that stopped reporting.
  -- @tparam {table...} hosts From Directory:list_hosts ({ hostname, age? }); `age` is
  --   nil for computers that have not reported since the controller started.
  function broker.check_offline(hosts)
    for _, host in ipairs(hosts) do
      local is_silent = host.age and host.age > dc_alerts.OFFLINE_SECONDS
      if is_silent and not broker.offline[host.hostname] then
        broker.offline[host.hostname] = true
        raise({ source = alerts.SYSTEM, key = offline_key(host.hostname), level = "info",
          title = host.hostname .. " stopped reporting",
          text = string.format("last report %d min ago (an unloaded chunk?)",
            math.floor(host.age / 60)),
          host = host.hostname })
      end
    end
  end

  --- Forget a computer that left the domain.
  -- @tparam string hostname
  function broker.forget(hostname)
    broker.offline[hostname] = nil
    tracker.forget(hostname)
  end

  return broker
end

return dc_alerts
