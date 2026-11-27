--- Alert channel: other computers, as an event on alerts.NOTIFY_PROTOCOL. `alerts watch`
-- shows them as they come (e.g. on a monitor), and programs can react to them
-- (rednet.receive(alerts.NOTIFY_PROTOCOL), then alerts.parse).
-- @module alert_channels.computer

local wire = import("wire")
local alerts = import("alerts")

local computer = {}

computer.kind = "computer"
computer.help = "a hostname, #<id>, or everyone (they run 'alerts watch' or a program)"

computer.EVERYONE = "everyone"

--- @tparam string target
-- @treturn[1] true
-- @treturn[2] nil
-- @treturn[2] string what is wrong
function computer.check(target)
  if target == computer.EVERYONE or target:match("^#?%d+$") or target:match("^[%w_%-%.]+$") then
    return true
  end
  return nil, "expected a hostname, #<id> or everyone"
end

--- @tparam string target
-- @treturn string
function computer.describe(target)
  if target == computer.EVERYONE then
    return "every computer"
  end
  return "computer " .. target
end

--- Send an alert.
-- @tparam string target
-- @tparam table alert
-- @tparam table env { send(id, message, protocol), broadcast(message, protocol),
--   resolve(name) -> id }
-- @treturn[1] true
-- @treturn[2] nil
-- @treturn[2] string error message
function computer.deliver(target, alert, env)
  local event = wire.event(alerts.ALERT_TOPIC, alert)
  if target == computer.EVERYONE then
    env.broadcast(event, alerts.NOTIFY_PROTOCOL)
    return true
  end
  local id = tonumber(target:match("^#?(%d+)$") or "")
  if not id then
    id = env.resolve(target)
  end
  if not id then
    return nil, "no computer called " .. target
  end
  env.send(id, event, alerts.NOTIFY_PROTOCOL)
  return true
end

return computer
