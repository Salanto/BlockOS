--- Alerts: one way for any program to say "something needs attention", and one place
-- (the alert hub, package alerts-hub) that decides who hears about it: a Discord
-- channel, any web service that takes a webhook, a mail to a user or group, or other
-- computers.
--
--   local alerts = import("alerts")
--   alerts.raise({ source = "reactor", key = "heat", level = "error",
--     title = "Reactor overheating", text = "1840 C" })
--   ...
--   alerts.raise({ source = "reactor", key = "heat", level = "ok", title = "Reactor cool" })
--
-- An alert is { source, level, title, text?, key?, host?, time? }:
--   source  who raised it, e.g. "logistics" (channels can pick sources)
--   level   "info", "warn" or "error"; "ok" says the problem with this key is over
--   key     names the problem within its source (e.g. an item), so a repeat is not sent
--           again for a while and "ok" knows what it resolves
--   host    the raising computer (filled in), time: seconds since the epoch (filled in)
--
-- The hub is found through the domain service record "alerts", else by rednet name.
-- Raising is one-way (it never waits for an answer), so it is safe in a service's loop.
--
-- Controllers are brokers: problems of a computer (notices with a level, see notices)
-- reach the hub through the domain controller, which tracks them per computer with
-- alerts.problem_tracker; the logistics hub raises for its nodes. So most code only
-- sets a notice, and alerts.raise is for code with its own reason to alert.
--
-- protocol PROTOCOL ("blockos.alerts"):
--   event ALERT_TOPIC (SCHEMA)       any computer -> the hub: raise an alert
--   rpc raise (SCHEMA)               the same, answered (tools; `alerts send`)
--   rpc list                         { channels, kinds, active, history }
--   rpc channel_set (ARGS.channel_set), channel_del { name }, test { name }
--                                    alerts-admins or domain-admins (open until set up)
-- protocol NOTIFY_PROTOCOL ("blockos.alerts.notify"):
--   event ALERT_TOPIC (SCHEMA)       the hub -> computers named by a "computer" channel;
--                                    read it with alerts.parse (see `alerts watch`)
-- @module alerts

local wire = import("wire")

local alerts = {}

alerts.PROTOCOL = "blockos.alerts"
alerts.NOTIFY_PROTOCOL = "blockos.alerts.notify"
alerts.SERVICE_TYPE = "alerts"
alerts.ALERT_TOPIC = "alert"
alerts.ADMINS = "alerts-admins"

--- Levels from least to most urgent. "ok" is not a level of its own: it resolves an
-- earlier alert with the same source and key.
alerts.LEVELS = { "info", "warn", "error" }
alerts.OK = "ok"

alerts.MAX_TITLE = 80
alerts.MAX_TEXT = 300

local NAME = { type = "string", max = 32 }

--- Payload of an alert (event data, and the raise rpc's args).
alerts.SCHEMA = {
  source = NAME,
  level = { type = "string", one_of = { "info", "warn", "error", "ok" } },
  title = { type = "string", max = alerts.MAX_TITLE },
  text = { type = "string", max = alerts.MAX_TEXT, optional = true },
  key = { type = "string", max = 64, optional = true },
  host = { type = "string", max = 64, optional = true },
  time = { type = "number", optional = true },
}

--- Argument schemas of the hub's rpc (see wire.validate).
alerts.ARGS = {
  channel_set = {
    name = NAME,
    kind = NAME,
    target = { type = "string", max = 256 },
    -- the least urgent level sent (default warn)
    min_level = { type = "string", one_of = alerts.LEVELS, optional = true },
    -- only these sources (default all)
    sources = { type = "table", max = 16, optional = true },
    -- send "ok" when a problem is over (default true)
    resolved = { type = "boolean", optional = true },
  },
  name = { name = NAME },
}

--- Discovery, sending and time (tests replace these).
alerts.env = {
  find = function(service_type, protocol)
    return import("discovery").find(service_type, protocol)
  end,
  forget = function(service_type) import("discovery").forget(service_type) end,
  send = function(id, message, protocol) rednet.send(id, message, protocol) end,
  now = function() return math.floor(os.epoch("utc") / 1000) end,
  clock = function() return os.clock() end,
}

-- How long "there is no hub" is believed: looking again is a broadcast and a 2 s wait
-- without a domain, and a program raising alerts should not stall on every one.
local MISS_SECONDS = 60
local missed_at = nil

--- How urgent a level is: 1 (info) to 3 (error); 0 for anything else.
-- @tparam string level
-- @treturn number
function alerts.rank(level)
  for index, name in ipairs(alerts.LEVELS) do
    if name == level then
      return index
    end
  end
  return 0
end

local function this_host()
  local net = blockos and blockos.net
  return net and net.full_hostname and net.full_hostname() or ("#" .. os.getComputerID())
end

--- Complete and check an alert: host and time are filled in, long text is cut.
-- @tparam table fields { source, level?, title, text?, key? } (level defaults to warn)
-- @treturn[1] table The alert.
-- @treturn[2] nil
-- @treturn[2] string what is wrong
function alerts.alert(fields)
  if type(fields) ~= "table" then
    return nil, "an alert is a table"
  end
  local alert = {
    source = fields.source,
    level = fields.level or "warn",
    title = type(fields.title) == "string" and fields.title:sub(1, alerts.MAX_TITLE)
      or fields.title,
    text = type(fields.text) == "string" and fields.text:sub(1, alerts.MAX_TEXT) or fields.text,
    key = fields.key,
    host = fields.host or this_host(),
    time = fields.time or alerts.env.now(),
  }
  local ok, err = wire.validate(alert, alerts.SCHEMA)
  if not ok then
    return nil, err
  end
  return alert
end

--- Build an alert event, checked against SCHEMA.
-- @tparam table fields See alerts.alert.
-- @treturn[1] table A wire event.
-- @treturn[2] nil
-- @treturn[2] string what is wrong
function alerts.event(fields)
  local alert, err = alerts.alert(fields)
  if not alert then
    return nil, err
  end
  return wire.event(alerts.ALERT_TOPIC, alert)
end

--- Read an alert event (from either protocol).
-- @param message A received rednet message.
-- @treturn[1] table The alert.
-- @treturn[2] nil
function alerts.parse(message)
  local event = wire.parse(message, "event", alerts.SCHEMA)
  if event and event.topic == alerts.ALERT_TOPIC then
    return event.data
  end
  return nil
end

--- The alert hub, if there is one.
-- @treturn[1] number Computer ID.
-- @treturn[2] nil
-- @treturn[2] string error message
function alerts.find_hub()
  local now = alerts.env.clock()
  if missed_at and now - missed_at < MISS_SECONDS then
    return nil, "no alert hub found (install alerts-hub on one computer)"
  end
  local id = alerts.env.find(alerts.SERVICE_TYPE, alerts.PROTOCOL)
  if not id then
    missed_at = now
    return nil, "no alert hub found (install alerts-hub on one computer)"
  end
  missed_at = nil
  return id
end

--- Raise an alert: send it to the hub and return at once.
-- @tparam table fields See alerts.alert.
-- @treturn[1] true It was sent (the hub decides who hears of it).
-- @treturn[2] nil
-- @treturn[2] string why not (bad alert, or no hub)
function alerts.raise(fields)
  local event, err = alerts.event(fields)
  if not event then
    return nil, err
  end
  local id, find_error = alerts.find_hub()
  if not id then
    return nil, find_error
  end
  alerts.env.send(id, event, alerts.PROTOCOL)
  return true
end

------------------------------------------------------------------------------
-- Brokers: controllers raise alerts for the computers that report to them
------------------------------------------------------------------------------

alerts.SYSTEM = "system"
alerts.MAX_PROBLEMS = 16
local SEND_EVENT = "blockos_alerts_send"

--- A sender that raises alerts from its own loop, so the caller (an rpc handler, a
-- report loop) never waits while the hub is looked up.
--
--   local sender = alerts.sender()
--   parallel.waitForAny(sender.run, ...)   -- and elsewhere: sender.raise({ ... })
-- @tparam[opt] function raise default alerts.raise
-- @treturn table { raise(fields), run() }
function alerts.sender(raise)
  raise = raise or alerts.raise
  local outbox = {}
  local sender = {}

  --- Queue an alert.
  -- @tparam table fields See alerts.alert.
  function sender.raise(fields)
    outbox[#outbox + 1] = fields
    os.queueEvent(SEND_EVENT)
  end

  --- Send queued alerts forever (run it next to the service's other loops).
  function sender.run()
    while true do
      local fields = table.remove(outbox, 1)
      if fields then
        pcall(raise, fields)
      else
        os.pullEvent(SEND_EVENT)
      end
    end
  end

  return sender
end

local function cut_key(host, key)
  return (host .. "/" .. key):sub(1, 64)
end

--- Turns the problems computers report (notices.problems: { key, text, level,
-- source? }) into alerts: a new problem, or one whose level changed, is raised; one
-- that is gone is resolved ("ok"). The alert's host is the computer with the problem.
-- @tparam function raise function(fields), e.g. a sender's raise
-- @treturn table { update(host, problems), forget(host) }
function alerts.problem_tracker(raise)
  local known = {} -- [host] = { [key] = { level, text, source } }
  local tracker = {}

  --- Take in the full list of a computer's problems.
  -- @tparam string host
  -- @tparam table problems
  function tracker.update(host, problems)
    local now = {}
    for index, problem in ipairs(type(problems) == "table" and problems or {}) do
      local is_valid = type(problem) == "table" and type(problem.key) == "string"
        and type(problem.text) == "string"
      if index > alerts.MAX_PROBLEMS then
        break
      elseif is_valid then
        local entry = {
          level = problem.level == "error" and "error" or "warn",
          text = problem.text,
          source = type(problem.source) == "string" and problem.source or alerts.SYSTEM,
        }
        local before = known[host] and known[host][problem.key]
        now[problem.key] = entry
        if not before or before.level ~= entry.level then
          raise({ source = entry.source, key = cut_key(host, problem.key), level = entry.level,
            title = entry.text, text = "on " .. host, host = host })
        end
      end
    end
    for key, before in pairs(known[host] or {}) do
      if not now[key] then
        raise({ source = before.source, key = cut_key(host, key), level = alerts.OK,
          title = "Fixed: " .. before.text, text = "on " .. host, host = host })
      end
    end
    known[host] = now
  end

  --- Forget a computer (it left the domain): nothing is resolved.
  -- @tparam string host
  function tracker.forget(host)
    known[host] = nil
  end

  return tracker
end

--- Call the hub and wait for the answer.
-- @tparam string op
-- @param[opt] args
-- @tparam[opt] table options rpc options (token, timeout, retries, relogin)
-- @return The result, or nil and an error message.
function alerts.call(op, args, options)
  missed_at = nil -- someone asks on purpose: look again
  local id, err = alerts.find_hub()
  if not id then
    return nil, err
  end
  local result, call_error = import("rpc").call(id, alerts.PROTOCOL, op, args, options)
  if not result and tostring(call_error):find("no answer") then
    alerts.env.forget(alerts.SERVICE_TYPE)
  end
  return result, call_error
end

return alerts
