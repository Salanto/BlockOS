--- The alert hub: receives alerts from every computer (see the alerts module) and sends
-- each one to the channels that want it.
--
-- A channel is { name, kind, target, min_level?, sources?, resolved? }: where alerts
-- go (kind and target, e.g. discord + a webhook URL) and which ones (at least
-- min_level, default warn; only these sources, default all; "ok" messages when a
-- problem is over, default yes). Channel kinds are files in lib/alert_channels/, so a
-- package adds a kind by shipping one more file there. A kind returns:
--   kind, help              its name, and what its target is (for people)
--   check(target)           -> true | nil, err
--   describe(target)        -> short text for lists (never a webhook's secret)
--   deliver(target, alert, env) -> true | nil, err   (env: alerts_hub.env)
--
-- Programs may raise the same alert over and over (a check in a loop): a repeat of an
-- active alert at the same level is only sent again after REPEAT_SECONDS. A level
-- change goes out at once, and "ok" only when the problem was active.
--
-- Every channel has its own queue, sent one alert per SPACING_SECONDS (webhooks have
-- rate limits). A failed delivery is retried after RETRY_SECONDS, MAX_ATTEMPTS times.
-- The channels are saved; active alerts and the history live in memory.
-- @module alerts_hub

local rpc = import("rpc")
local alerts = import("alerts")

local alerts_hub = {}

alerts_hub.REPEAT_SECONDS = 300
alerts_hub.MAX_HISTORY = 30
alerts_hub.MAX_QUEUE = 20
alerts_hub.MAX_CHANNELS = 16
alerts_hub.SPACING_SECONDS = 1
alerts_hub.RETRY_SECONDS = 30
alerts_hub.MAX_ATTEMPTS = 3
alerts_hub.DEFAULT_LEVEL = "warn"
alerts_hub.CONFIG_FILE = "etc/blockos/alerts-hub"

local KIND_DIR = "lib/alert_channels"

-- What a failed HTTP request answered, e.g. "HTTP 404: Unknown Webhook".
local function describe_failure(err, failed)
  if not failed then
    return tostring(err)
  end
  local code = failed.getResponseCode()
  local body = failed.readAll() or ""
  failed.close()
  local message = body:match('"message"%s*:%s*"([^"]*)"') or body:sub(1, 60)
  return string.format("HTTP %d%s", code, message ~= "" and (": " .. message) or "")
end

--- POST a table as JSON to a URL.
-- @tparam string url
-- @tparam table body
-- @treturn[1] true
-- @treturn[2] nil
-- @treturn[2] string error message
local function post_json(url, body)
  if not http then
    return nil, "HTTP is turned off on this server (CC:Tweaked config: http enabled)"
  end
  local encoded, json = pcall(textutils.serializeJSON, body)
  if not encoded then
    return nil, "cannot encode the alert: " .. tostring(json)
  end
  local handle, err, failed = http.post(url, json,
    { ["Content-Type"] = "application/json" })
  if not handle then
    return nil, describe_failure(err, failed)
  end
  local code = handle.getResponseCode()
  handle.close()
  if code >= 300 then
    return nil, "HTTP " .. code
  end
  return true
end

--- How channels reach the world, and time (tests replace these). Passed to every
-- channel kind's deliver.
alerts_hub.env = {
  post = post_json,
  send = function(id, message, protocol) rednet.send(id, message, protocol) end,
  broadcast = function(message, protocol) rednet.broadcast(message, protocol) end,
  resolve = function(name) return import("net").resolve(name) end,
  mail = function(to, subject, text)
    local found, mail_protocol = pcall(import, "mail_protocol")
    if not found then
      return nil, "mail-protocol is not installed on the alert hub"
    end
    return mail_protocol.call("send", { to = to, subject = subject, text = text })
  end,
  clock = function() return os.clock() end,
}

--- Load every channel kind.
-- @tparam[opt] string root System tree (default blockos.root).
-- @tparam[opt] function loader Module loader (default import; tests pass their own).
-- @treturn table [kind] = module
function alerts_hub.load_kinds(root, loader)
  loader = loader or import
  root = root or (blockos and blockos.root) or "/blockos"
  local kinds = {}
  local dir = fs.combine(root, KIND_DIR)
  if not fs.isDir(dir) then
    return kinds
  end
  for _, file in ipairs(fs.list(dir)) do
    local name = file:match("^(.-)%.lua$")
    if name then
      local ok, kind = pcall(loader, "alert_channels/" .. name)
      if ok and type(kind) == "table" and type(kind.deliver) == "function" then
        kinds[kind.kind or name] = kind
      end
    end
  end
  return kinds
end

local function contains(list, value)
  for _, entry in ipairs(list) do
    if entry == value then
      return true
    end
  end
  return false
end

local function copy(value)
  local result = {}
  for key, entry in pairs(value) do
    result[key] = entry
  end
  return result
end

--- Create a hub.
-- @tparam table options
--   kinds    [kind] = module (alerts_hub.load_kinds)
--   config   { channels = { [name] = channel } }, saved by `save`
--   save     function() -> true | nil, err
--   wake     function() called when an alert was queued (starts the delivery loop)
-- @treturn table hub
function alerts_hub.new(options)
  local kinds = options.kinds or {}
  local config = options.config or {}
  config.channels = config.channels or {}
  local save = options.save or function() return true end
  local wake = options.wake or function() end

  local hub = {
    active = {}, -- [source/key] = { alert, sent_at }
    history = {}, -- newest last
    status = {}, -- [channel name] = { queue, sent, failed, dropped, last_error, next_at }
  }

  local function status_of(name)
    local status = hub.status[name]
    if not status then
      status = { queue = {}, sent = 0, failed = 0, dropped = 0 }
      hub.status[name] = status
    end
    return status
  end

  -- Does this channel want an alert as urgent as `rank`?
  local function wants(channel, alert, rank)
    if alert.level == alerts.OK and channel.resolved == false then
      return false
    end
    if rank < alerts.rank(channel.min_level or alerts_hub.DEFAULT_LEVEL) then
      return false
    end
    local sources = channel.sources
    return not sources or #sources == 0 or contains(sources, alert.source)
  end

  local function enqueue(name, alert)
    local status = status_of(name)
    status.queue[#status.queue + 1] = { alert = alert, attempts = 0 }
    if #status.queue > alerts_hub.MAX_QUEUE then
      table.remove(status.queue, 1)
      status.dropped = status.dropped + 1
    end
  end

  local function remember(alert)
    hub.history[#hub.history + 1] = alert
    if #hub.history > alerts_hub.MAX_HISTORY then
      table.remove(hub.history, 1)
    end
  end

  -- How urgent an alert counts for routing, or nil when it should not go out: a
  -- repeat, or an "ok" for a problem nobody heard of.
  local function routing_rank(alert)
    local key = alert.key and (alert.source .. "/" .. alert.key)
    local now = alerts_hub.env.clock()
    if alert.level == alerts.OK then
      local was = key and hub.active[key]
      if not key then
        return 1
      elseif not was then
        return nil
      end
      hub.active[key] = nil
      return alerts.rank(was.alert.level)
    end
    if key then
      local was = hub.active[key]
      local is_repeat = was and was.alert.level == alert.level
        and now - was.sent_at < alerts_hub.REPEAT_SECONDS
      if is_repeat then
        was.alert = alert -- keep the newest text for the list
        return nil
      end
      hub.active[key] = { alert = alert, sent_at = now }
    end
    return alerts.rank(alert.level)
  end

  --- Take in an alert and queue it for every channel that wants it.
  -- @tparam table alert Checked against alerts.SCHEMA.
  -- @treturn table { queued = number of channels, is_repeat? }
  function hub.receive(alert)
    local rank = routing_rank(alert)
    if not rank then
      return { queued = 0, is_repeat = true }
    end
    remember(alert)
    local queued = 0
    for name, channel in pairs(config.channels) do
      if wants(channel, alert, rank) then
        enqueue(name, alert)
        queued = queued + 1
      end
    end
    if queued > 0 then
      wake()
    end
    return { queued = queued }
  end

  local function deliver(channel, alert)
    local kind = kinds[channel.kind]
    if not kind then
      return nil, "unknown channel kind " .. tostring(channel.kind)
    end
    local ran, ok, err = pcall(kind.deliver, channel.target, alert, alerts_hub.env)
    if not ran then
      return nil, tostring(ok)
    end
    if not ok then
      return nil, err or "failed"
    end
    return true
  end

  local function deliver_head(name, status)
    local entry = status.queue[1]
    local channel = config.channels[name]
    if not channel then
      status.queue = {}
      return
    end
    local ok, err = deliver(channel, entry.alert)
    local now = alerts_hub.env.clock()
    if ok then
      table.remove(status.queue, 1)
      status.sent = status.sent + 1
      status.last_error = nil
      status.next_at = now + alerts_hub.SPACING_SECONDS
      return
    end
    entry.attempts = entry.attempts + 1
    status.failed = status.failed + 1
    status.last_error = err
    if entry.attempts >= alerts_hub.MAX_ATTEMPTS then
      table.remove(status.queue, 1)
      status.dropped = status.dropped + 1
    end
    status.next_at = now + alerts_hub.RETRY_SECONDS
  end

  --- Send what is due: at most one alert per channel.
  -- @treturn number|nil Seconds until the next one is due, or nil when nothing waits.
  function hub.deliver_due()
    local next_wait = nil
    for name, status in pairs(hub.status) do
      if status.queue[1] and alerts_hub.env.clock() >= (status.next_at or 0) then
        deliver_head(name, status)
      end
      if status.queue[1] then
        local wait = math.max(0, (status.next_at or 0) - alerts_hub.env.clock())
        next_wait = math.min(next_wait or wait, wait)
      end
    end
    return next_wait
  end

  --- Send a test alert to one channel now, past its queue and filters.
  -- @tparam string name
  -- @treturn[1] true
  -- @treturn[2] nil
  -- @treturn[2] string error message
  function hub.test(name)
    local channel = config.channels[name]
    if not channel then
      return nil, "no channel called " .. name
    end
    local alert = alerts.alert({
      source = "alerts",
      level = "info",
      title = "Test alert",
      text = "If you can read this, channel '" .. name .. "' works.",
    })
    return deliver(channel, alert)
  end

  --- Add or change a channel.
  -- @tparam table args alerts.ARGS.channel_set
  -- @treturn[1] true
  -- @treturn[2] nil
  -- @treturn[2] string error message
  function hub.set_channel(args)
    local kind = kinds[args.kind]
    if not kind then
      return nil, "unknown channel kind " .. args.kind .. " (kinds: "
        .. table.concat(hub.kind_names(), ", ") .. ")"
    end
    local ok, err = kind.check(args.target)
    if not ok then
      return nil, err
    end
    local count = 0
    for _ in pairs(config.channels) do
      count = count + 1
    end
    if not config.channels[args.name] and count >= alerts_hub.MAX_CHANNELS then
      return nil, "too many channels (at most " .. alerts_hub.MAX_CHANNELS .. ")"
    end
    local sources = nil
    for _, source in ipairs(args.sources or {}) do
      if type(source) == "string" and source ~= "" then
        sources = sources or {}
        sources[#sources + 1] = source:sub(1, 32)
      end
    end
    local previous = config.channels[args.name]
    config.channels[args.name] = {
      name = args.name,
      kind = args.kind,
      target = args.target,
      min_level = args.min_level,
      sources = sources,
      resolved = args.resolved,
    }
    local saved, save_error = save()
    if not saved then
      config.channels[args.name] = previous
      return nil, save_error
    end
    return true
  end

  --- Remove a channel (and whatever it still had queued).
  -- @tparam string name
  -- @treturn[1] true
  -- @treturn[2] nil
  -- @treturn[2] string error message
  function hub.del_channel(name)
    local previous = config.channels[name]
    if not previous then
      return nil, "no channel called " .. name
    end
    config.channels[name] = nil
    local saved, save_error = save()
    if not saved then
      config.channels[name] = previous
      return nil, save_error
    end
    hub.status[name] = nil
    return true
  end

  --- @treturn {string...} The channel kinds this hub knows, sorted.
  function hub.kind_names()
    local names = {}
    for name in pairs(kinds) do
      names[#names + 1] = name
    end
    table.sort(names)
    return names
  end

  --- Active alerts, sorted by source and key.
  -- @treturn {table...}
  function hub.active_list()
    local list = {}
    for _, entry in pairs(hub.active) do
      list[#list + 1] = entry.alert
    end
    table.sort(list, function(a, b)
      return (a.source .. "/" .. a.key) < (b.source .. "/" .. b.key)
    end)
    return list
  end

  --- Everything a tool shows.
  -- @treturn table { channels, kinds, active, history }
  function hub.list()
    local channels = {}
    for name, channel in pairs(config.channels) do
      local status = status_of(name)
      local kind = kinds[channel.kind]
      local entry = copy(channel)
      entry.target = nil -- webhook URLs hold their secret: describe them instead
      entry.describe = kind and kind.describe(channel.target) or channel.kind
      entry.min_level = channel.min_level or alerts_hub.DEFAULT_LEVEL
      entry.queued = #status.queue
      entry.sent, entry.failed, entry.dropped = status.sent, status.failed, status.dropped
      entry.last_error = status.last_error
      channels[#channels + 1] = entry
    end
    table.sort(channels, function(a, b) return a.name < b.name end)
    local kind_list = {}
    for _, name in ipairs(hub.kind_names()) do
      kind_list[#kind_list + 1] = { kind = name, help = kinds[name].help }
    end
    return {
      channels = channels,
      kinds = kind_list,
      active = hub.active_list(),
      history = hub.history,
    }
  end

  return hub
end

local function roles_module()
  local found, roles = pcall(import, "roles")
  return found and roles or nil
end

--- Build the rpc handlers (see the alerts module).
-- @tparam table hub From alerts_hub.new.
-- @treturn table handlers
function alerts_hub.handlers(hub)
  local handlers = {}
  local with_args = rpc.with_args

  -- Channels are open until `domain setup alerts`, then alerts-admins or domain-admins.
  local function admin(fn)
    return function(ctx, args)
      local roles = roles_module()
      if roles then
        local ok, err = roles.require(ctx, alerts.ADMINS, { admins = true })
        if not ok then
          return nil, err
        end
      end
      return fn(ctx, args)
    end
  end

  handlers.raise = with_args(alerts.SCHEMA, function(ctx, args)
    local alert = copy(args)
    alert.host = alert.host or ("#" .. tostring(ctx.sender))
    return hub.receive(alert)
  end)

  function handlers.list()
    return hub.list()
  end

  handlers.channel_set = with_args(alerts.ARGS.channel_set, admin(function(_, args)
    return hub.set_channel(args)
  end))

  handlers.channel_del = with_args(alerts.ARGS.name, admin(function(_, args)
    return hub.del_channel(args.name)
  end))

  handlers.test = with_args(alerts.ARGS.name, admin(function(_, args)
    return hub.test(args.name)
  end))

  return handlers
end

--- Take in an alert event that arrived over rednet.
-- @tparam table hub
-- @tparam number sender
-- @param message
-- @treturn[1] table What hub.receive answered.
-- @treturn[2] nil Not an alert.
function alerts_hub.on_message(hub, sender, message)
  local alert = alerts.parse(message)
  if not alert then
    return nil
  end
  alert = copy(alert)
  alert.host = alert.host or ("#" .. tostring(sender))
  return hub.receive(alert)
end

return alerts_hub
