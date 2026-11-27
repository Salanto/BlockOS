-- alerts: the network's alerts and where they go (see the alert hub, package alerts-hub).
--
--   alerts                         active alerts and the recent history
--   alerts channels                channels, what they get and how delivery goes
--   alerts add <name> <kind> <target> [--level=info|warn|error] [--source=a,b]
--                                  [--no-resolved]
--                                  add or change a channel; kinds: discord (webhook
--                                  URL), webhook (any URL, JSON), mail (user or group),
--                                  computer (hostname, #id or everyone)
--   alerts remove <name>
--   alerts test <name>             send a test alert to one channel now
--   alerts send [--level=..] [--source=..] [--key=..] <title...>
--                                  raise an alert by hand (also from scripts)
--   alerts watch                   show alerts sent to this computer ("computer"
--                                  channels) as they arrive; q quits
local args = { ... }
local ui = blockos.ui
local alerts = import("alerts")

local LEVEL_ROLES = { info = "text", warn = "warn", error = "error", ok = "ok" }

-- Programs may ask for the password again when a login expired.
local function call(op, call_args)
  return alerts.call(op, call_args, { relogin = true })
end

local function print_usage()
  print("Usage: alerts | alerts channels | alerts watch")
  print("       alerts add <name> <kind> <target> [--level=warn]")
  print("              [--source=a,b] [--no-resolved]")
  print("       alerts remove <name> | alerts test <name>")
  print("       alerts send [--level=warn] [--source=me] [--key=k] <title...>")
end

-- Raise, so scripts (alerts send ...) notice a failure.
local function fail(message)
  error(tostring(message), 0)
end

-- Split "--name=value" flags from the other words.
local function parse(words)
  local options, rest = {}, {}
  for _, word in ipairs(words) do
    local name, value = word:match("^%-%-([%w%-]+)=(.*)$")
    if name then
      options[name] = value
    elseif word:match("^%-%-[%w%-]+$") then
      options[word:sub(3)] = true
    else
      rest[#rest + 1] = word
    end
  end
  return options, rest
end

local function split_list(text)
  local list = {}
  for entry in tostring(text):gmatch("[^,%s]+") do
    list[#list + 1] = entry
  end
  return list
end

local function describe(alert)
  local text = alert.title
  if alert.text then
    text = text .. ": " .. alert.text
  end
  return string.format("[%s] %s (%s@%s)", alert.level, text, alert.source,
    tostring(alert.host))
end

local function show_overview()
  local result, err = call("list")
  if not result then
    return fail(err)
  end
  ui.title("Active alerts")
  if #result.active == 0 then
    ui.print("  (none)", "faint")
  end
  for _, alert in ipairs(result.active) do
    ui.status(describe(alert), LEVEL_ROLES[alert.level])
  end
  print()
  ui.title("Recent (newest first)")
  local history = result.history
  if #history == 0 then
    ui.print("  (none)", "faint")
  end
  for index = #history, math.max(1, #history - 9), -1 do
    local alert = history[index]
    ui.status(describe(alert), LEVEL_ROLES[alert.level])
  end
  if #result.channels == 0 then
    print()
    ui.print("No channels yet: alerts add <name> <kind> <target>", "dim")
  end
end

local function channel_line(channel)
  local what = channel.min_level .. "+"
  if channel.sources then
    what = what .. " from " .. table.concat(channel.sources, ",")
  end
  if channel.resolved == false then
    what = what .. ", no ok"
  end
  return string.format("%s: %s (%s) sent %d", channel.name, channel.describe, what,
    channel.sent)
end

local function show_channels()
  local result, err = call("list")
  if not result then
    return fail(err)
  end
  ui.title("Alert channels")
  if #result.channels == 0 then
    ui.print("  (none)", "faint")
  end
  for _, channel in ipairs(result.channels) do
    local role = channel.last_error and "error" or "ok"
    ui.status(channel_line(channel), role)
    if channel.queued > 0 then
      ui.print("    " .. channel.queued .. " waiting", "dim")
    end
    if channel.last_error then
      ui.print("    " .. channel.last_error, "error")
    end
  end
  print()
  ui.title("Kinds")
  for _, kind in ipairs(result.kinds) do
    ui.field(kind.kind, kind.help, "dim")
  end
end

local function add_channel(words)
  local options, rest = parse(words)
  local name, kind, target = rest[1], rest[2], rest[3]
  if not (name and kind and target) then
    return print_usage()
  end
  local result, err = call("channel_set", {
    name = name,
    kind = kind,
    target = target,
    min_level = type(options.level) == "string" and options.level or nil,
    sources = type(options.source) == "string" and split_list(options.source) or nil,
    resolved = options["no-resolved"] and false or nil,
  })
  if not result then
    return fail(err)
  end
  ui.print("Channel " .. name .. " saved. Try it: alerts test " .. name, "ok")
end

local function remove_channel(name)
  if not name then
    return print_usage()
  end
  local result, err = call("channel_del", { name = name })
  if not result then
    return fail(err)
  end
  ui.print("Channel " .. name .. " removed.", "ok")
end

local function test_channel(name)
  if not name then
    return print_usage()
  end
  local result, err = call("test", { name = name })
  if not result then
    return fail("Test failed: " .. tostring(err))
  end
  ui.print("Sent a test alert to " .. name .. ".", "ok")
end

local function send_alert(words)
  local options, rest = parse(words)
  if #rest == 0 then
    return print_usage()
  end
  local user = blockos.user and blockos.user.name
  local alert, err = alerts.alert({
    source = type(options.source) == "string" and options.source or user or "shell",
    level = type(options.level) == "string" and options.level or "warn",
    key = type(options.key) == "string" and options.key or nil,
    title = table.concat(rest, " "),
  })
  if not alert then
    return fail(err)
  end
  local result, call_error = call("raise", alert)
  if not result then
    return fail(call_error)
  end
  if result.is_repeat then
    ui.print("Already active: not sent again yet.", "dim")
  else
    ui.print("Raised; sent to " .. result.queued .. " channel(s).", "ok")
  end
end

local function watch()
  ui.title("Alerts for this computer (q quits)")
  ui.print("A channel of kind computer must name it (or everyone).", "dim")
  while true do
    local event, a, b, c = os.pullEvent()
    if event == "rednet_message" and c == alerts.NOTIFY_PROTOCOL then
      local alert = alerts.parse(b)
      if alert then
        ui.status(textutils.formatTime(os.time(), true) .. " " .. describe(alert),
          LEVEL_ROLES[alert.level])
      end
    elseif event == "char" and a == "q" then
      return
    end
  end
end

local command = args[1]
local rest = { table.unpack(args, 2) }
if command == nil or command == "list" then
  show_overview()
elseif command == "channels" then
  show_channels()
elseif command == "add" then
  add_channel(rest)
elseif command == "remove" then
  remove_channel(rest[1])
elseif command == "test" then
  test_channel(rest[1])
elseif command == "send" then
  send_alert(rest)
elseif command == "watch" then
  watch()
else
  print_usage()
end
