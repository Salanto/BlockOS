--- Stock watching logic: watches, limits, alarms to raise and who may access.
--
-- Pure functions over plain tables, so everything here is unit-tested without
-- any hardware. The storage-monitor service feeds it item counts.
--
-- Config (/etc/blockos/storage-monitor):
--   poll_seconds     how often storage is read
--   chime            play the alarm sound when an item goes low
--   sound            { kind = "note" | "sound" | "file", value, volume } (see stock_alarms)
--   watches          [item] = { label, limit, refill_to?, outputs = { { target, side }... } }
--                    (low below `limit`, recovered at `refill_to` or a small margin above)
--   any_low_outputs  redstone outputs that are on while any item is low
--   access           { admins = {...}, viewers = {...}, computers = {...} }
--   name             optional: this stock computer's name ("kitchen")
-- @module stock

local stock = {}

stock.DEFAULT_POLL_SECONDS = 10
stock.DEFAULT_SHARE = 0.5
stock.RECOVERY_MARGIN = 0.05
stock.SIDES = { "top", "bottom", "left", "right", "front", "back" }
stock.DOMAIN_ADMINS = "domain-admins"

local VALID_SIDES = {}
for _, side in ipairs(stock.SIDES) do
  VALID_SIDES[side] = true
end

--- A fresh config.
-- @tparam {string...} admins Users or groups who may configure it.
-- @tparam[opt] string name
-- @treturn table
function stock.new_config(admins, name)
  return stock.normalise({ access = { admins = admins }, name = name })
end

--- Fill in anything missing (also for configs saved by older versions).
-- @tparam table config
-- @treturn table The same table.
function stock.normalise(config)
  config.poll_seconds = config.poll_seconds or stock.DEFAULT_POLL_SECONDS
  if config.chime == nil then
    config.chime = true
  end
  config.sound = config.sound or { kind = "note", value = "bell", volume = 3 }
  config.watches = config.watches or {}
  config.any_low_outputs = config.any_low_outputs or {}
  config.access = config.access or {}
  config.access.admins = config.access.admins or {}
  config.access.viewers = config.access.viewers or {}
  config.access.computers = config.access.computers or {}
  return config
end

--- Check a redstone output { target, side }.
-- @treturn[1] true
-- @treturn[2] nil
-- @treturn[2] string error message
function stock.validate_output(output)
  if type(output) ~= "table" or type(output.target) ~= "string" or output.target == "" then
    return nil, "an output needs a target (computer or a relay)"
  end
  if not VALID_SIDES[output.side] then
    return nil, "an output needs a side: " .. table.concat(stock.SIDES, ", ")
  end
  return true
end

--- Check and clean a watch before it is stored.
-- @tparam table watch { label, limit, refill_to?, outputs }
-- @treturn[1] table The cleaned watch.
-- @treturn[2] nil
-- @treturn[2] string error message
function stock.clean_watch(watch)
  local limit = tonumber(watch.limit)
  if not limit or limit < 1 then
    return nil, "the limit must be a number of at least 1"
  end
  limit = math.floor(limit)
  local refill_to = watch.refill_to and tonumber(watch.refill_to)
  if watch.refill_to and (not refill_to or refill_to <= limit) then
    return nil, "the refill target must be above the limit"
  end
  local outputs = {}
  for _, output in ipairs(watch.outputs or {}) do
    local ok, err = stock.validate_output(output)
    if not ok then
      return nil, err
    end
    outputs[#outputs + 1] = { target = output.target, side = output.side }
  end
  return {
    label = watch.label,
    limit = limit,
    refill_to = refill_to and math.floor(refill_to),
    outputs = outputs,
  }
end

--- The count at which a low item counts as recovered: its refill target when
-- set (e.g. a farm runs from 200 until 1000), otherwise a small margin above
-- the limit so lamps do not flicker when stock hovers around it.
-- @tparam table watch { limit, refill_to? }
-- @treturn number
function stock.recovery_level(watch)
  if watch.refill_to then
    return watch.refill_to
  end
  return watch.limit + math.max(1, math.ceil(watch.limit * stock.RECOVERY_MARGIN))
end

--- Compare current counts with the watches.
-- @tparam table config
-- @tparam table totals [item] = { count, label } from the storage sources.
-- @tparam[opt] table previous The states from the last call.
-- @treturn table states: [item] = { label, count, limit, is_low }
-- @treturn table changes: { went_low = {item...}, recovered = {item...} }
function stock.evaluate(config, totals, previous)
  previous = previous or {}
  local states = {}
  local changes = { went_low = {}, recovered = {} }
  for item, watch in pairs(config.watches) do
    local found = totals[item]
    local count = found and found.count or 0
    local was_low = previous[item] ~= nil and previous[item].is_low
    local is_low
    if was_low then
      is_low = count < stock.recovery_level(watch)
    else
      is_low = count < watch.limit
    end
    states[item] = {
      label = watch.label or (found and found.label) or item,
      count = count,
      limit = watch.limit,
      refill_to = watch.refill_to,
      is_low = is_low,
    }
    if is_low and not was_low then
      changes.went_low[#changes.went_low + 1] = item
    elseif was_low and not is_low then
      changes.recovered[#changes.recovered + 1] = item
    end
  end
  table.sort(changes.went_low)
  table.sort(changes.recovered)
  return states, changes
end

local function output_key(output)
  return output.target .. "|" .. output.side
end

--- Which redstone outputs should be on. An output is on while any item mapped
-- to it is low; the any-low outputs are on while any item at all is low.
-- @tparam table config
-- @tparam table states From stock.evaluate.
-- @treturn table [ "target|side" ] = { target, side, is_on }
function stock.output_states(config, states)
  local outputs = {}
  local function add(output, is_on)
    local key = output_key(output)
    local entry = outputs[key] or { target = output.target, side = output.side, is_on = false }
    entry.is_on = entry.is_on or is_on
    outputs[key] = entry
  end

  local any_low = false
  for item, watch in pairs(config.watches) do
    local is_low = states[item] ~= nil and states[item].is_low
    any_low = any_low or is_low
    for _, output in ipairs(watch.outputs or {}) do
      add(output, is_low)
    end
  end
  for _, output in ipairs(config.any_low_outputs) do
    add(output, any_low)
  end
  return outputs
end

--- Outputs for reactions on another computer: each { item, target, side } is
-- on while that item is low.
-- @tparam {table...} reactions
-- @tparam table item_low [item] = true while low
-- @treturn table [ "target|side" ] = { target, side, is_on }
function stock.reaction_outputs(reactions, item_low)
  local outputs = {}
  for _, reaction in ipairs(reactions) do
    local key = output_key(reaction)
    local entry = outputs[key] or { target = reaction.target, side = reaction.side, is_on = false }
    entry.is_on = entry.is_on or item_low[reaction.item] == true
    outputs[key] = entry
  end
  return outputs
end

--- Watch every item in storage that is not watched yet, with a limit of a
-- share of its current count (rounded down, at least 1).
-- @tparam table config
-- @tparam table totals [item] = { count, label }
-- @tparam[opt] number share e.g. 0.5 for half of the current count.
-- @treturn number How many items were added.
function stock.watch_from_contents(config, totals, share)
  share = share or stock.DEFAULT_SHARE
  local added = 0
  for item, found in pairs(totals) do
    if not config.watches[item] and found.count > 0 then
      config.watches[item] = {
        label = found.label,
        limit = math.max(1, math.floor(found.count * share)),
        outputs = {},
      }
      added = added + 1
    end
  end
  return added
end

------------------------------------------------------------------------------
-- Access
------------------------------------------------------------------------------

local function is_listed(list, user)
  for _, entry in ipairs(list) do
    if entry == user.name then
      return true
    end
    for _, group in ipairs(user.groups or {}) do
      if entry == group then
        return true
      end
    end
  end
  return false
end

--- What a domain user may do here: "admin", "viewer" or nil.
-- Domain admins always count as admins.
-- @tparam table config
-- @tparam table user { name, groups }
-- @treturn string|nil
function stock.access_level(config, user)
  if is_listed({ stock.DOMAIN_ADMINS }, user) or is_listed(config.access.admins, user) then
    return "admin"
  end
  if is_listed(config.access.viewers, user) then
    return "viewer"
  end
  return nil
end

--- May this domain computer pull data and receive alerts?
-- @tparam table config
-- @tparam string hostname
-- @treturn boolean
function stock.is_computer_allowed(config, hostname)
  for _, allowed in ipairs(config.access.computers) do
    if allowed == hostname then
      return true
    end
  end
  return false
end

--- Rows for display, sorted: low items first, then by label.
-- @tparam table states From stock.evaluate.
-- @treturn {table...} { item, label, count, limit, refill_to, is_low }
function stock.sorted_rows(states)
  local rows = {}
  for item, state in pairs(states) do
    rows[#rows + 1] = {
      item = item,
      label = state.label,
      count = state.count,
      limit = state.limit,
      refill_to = state.refill_to,
      is_low = state.is_low,
    }
  end
  table.sort(rows, function(a, b)
    if a.is_low ~= b.is_low then
      return a.is_low
    end
    return tostring(a.label) < tostring(b.label)
  end)
  return rows
end

return stock
