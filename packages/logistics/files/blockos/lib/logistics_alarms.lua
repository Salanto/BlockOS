--- Logistics alarms: redstone outputs, a speaker chime and network alerts.
--
-- Redstone goes out of the computer's own sides or out of CC Redstone Relays
-- anywhere on the wired network (plain on/off). A relay or computer side can
-- feed lamps directly or a Create Redstone Link for wireless lamps.
-- @module logistics_alarms

local logistics = import("logistics")
local wire = import("wire")

local logistics_alarms = {}

logistics_alarms.ALERT_PROTOCOL = "blockos.logistics.alert"
logistics_alarms.ALERT_TOPIC = "level_alert"
logistics_alarms.COMPUTER = "computer"
logistics_alarms.RELAY_TYPE = "redstone_relay"
logistics_alarms.EVERYONE = "everyone"

--- Payload of a level alert event.
logistics_alarms.ALERT_SCHEMA = {
  server = "string",
  item = "string",
  label = { type = "string", optional = true },
  count = "number",
  limit = "number",
  is_low = "boolean",
}

--- Hardware and network access (tests replace these with stubs).
logistics_alarms.env = {
  peripheral = peripheral,
  redstone = redstone,
  send = function(recipient, message, protocol) rednet.send(recipient, message, protocol) end,
  broadcast = function(message, protocol) rednet.broadcast(message, protocol) end,
}

--- Redstone targets that can be chosen: this computer and every relay.
-- @treturn {table...} { target, sides }
function logistics_alarms.list_outputs()
  local targets = { { target = logistics_alarms.COMPUTER, sides = logistics.SIDES } }
  for _, name in ipairs(logistics_alarms.env.peripheral.getNames()) do
    if logistics_alarms.env.peripheral.hasType(name, logistics_alarms.RELAY_TYPE) then
      targets[#targets + 1] = { target = name, sides = logistics.SIDES }
    end
  end
  return targets
end

local function set_output(target, side, is_on)
  if target == logistics_alarms.COMPUTER then
    logistics_alarms.env.redstone.setOutput(side, is_on)
    return true
  end
  local relay = logistics_alarms.env.peripheral.wrap(target)
  if relay and relay.setOutput then
    relay.setOutput(side, is_on)
    return true
  end
  return false
end

--- Apply the wanted output states. Outputs that were on last time but are no
-- longer configured are switched off.
-- @tparam table wanted From logistics.output_states.
-- @tparam table applied The table returned by the previous call (or {}).
-- @treturn table The outputs now applied (pass it in next time).
function logistics_alarms.apply_redstone(wanted, applied)
  for key, output in pairs(applied) do
    if output.is_on and not wanted[key] then
      pcall(set_output, output.target, output.side, false)
    end
  end
  local now_applied = {}
  for key, output in pairs(wanted) do
    pcall(set_output, output.target, output.side, output.is_on)
    now_applied[key] = output
  end
  return now_applied
end

--- The alarm sound used when nothing is configured: a short bell.
logistics_alarms.DEFAULT_SOUND = { kind = "note", value = "bell", volume = 3 }

--- Check an alarm sound (see the core sound module).
function logistics_alarms.validate_sound(value)
  return import("sound").validate(value)
end

--- Play the alarm sound on an attached speaker, if there is one.
-- @tparam[opt] table value See the core sound module; default a bell.
-- @treturn[1] true
-- @treturn[2] nil
-- @treturn[2] string why nothing played
function logistics_alarms.chime(value)
  local sound = import("sound")
  sound.env.peripheral = logistics_alarms.env.peripheral
  return sound.play(value or logistics_alarms.DEFAULT_SOUND)
end

--- Build the alert event for one changed item.
-- @tparam string server The hub's hostname (controller or lone node).
-- @tparam string item
-- @tparam table state From logistics.evaluate.
-- @treturn table A wire event.
function logistics_alarms.alert(server, item, state)
  return wire.event(logistics_alarms.ALERT_TOPIC, {
    server = server,
    item = item,
    label = state.label,
    count = state.count,
    limit = state.limit,
    is_low = state.is_low,
  })
end

--- Send alerts for every change to each computer ID given, or to everyone.
-- Alerts only go out when an item goes low or recovers, so a broadcast is rare.
-- @tparam string server
-- @tparam table states
-- @tparam table changes From logistics.evaluate.
-- @tparam {number...}|string recipients Computer IDs, or logistics_alarms.EVERYONE.
-- @treturn {table...} The alert payloads sent (for the alert history).
function logistics_alarms.send_alerts(server, states, changes, recipients)
  local sent = {}
  local changed = {}
  for _, item in ipairs(changes.went_low) do
    changed[#changed + 1] = item
  end
  for _, item in ipairs(changes.recovered) do
    changed[#changed + 1] = item
  end
  local cleared = changes.cleared or {}
  for _, item in ipairs(changed) do
    local event = logistics_alarms.alert(server, item, states[item] or cleared[item])
    if recipients == logistics_alarms.EVERYONE then
      logistics_alarms.env.broadcast(event, logistics_alarms.ALERT_PROTOCOL)
    else
      for _, recipient in ipairs(recipients) do
        logistics_alarms.env.send(recipient, event, logistics_alarms.ALERT_PROTOCOL)
      end
    end
    sent[#sent + 1] = event.data
  end
  return sent
end

return logistics_alarms
