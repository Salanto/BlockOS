--- Logistics logic shared by the controller and the nodes: levels (watched items with
-- limits and alarms), storage roles and labels, and finding items and chests by name.
--
-- Pure functions over plain tables, so everything here is unit-tested without any
-- hardware.
--
-- Levels config (the controller's /etc/blockos/logistics-controller, or a lone node's
-- /etc/blockos/logistics-levels):
--   chime            play the alarm sound when an item goes low
--   sound            { kind = "note" | "sound" | "file", value, volume } (see logistics_alarms)
--   watches          [item] = { label, limit, refill_to?, outputs = { { target, side }... } }
--                    (low below `limit`, recovered at `refill_to` or a small margin above)
--   any_low_outputs  redstone outputs that are on while any item is low
--   name             optional: the controller's name ("kitchen")
--
-- Node config (/etc/blockos/logistics-node):
--   poll_seconds     how often storage is read
--   storage_side     the modem of the storage network (closed for rednet)
--   storages         [handle] = { role?, label?, pos? } per inventory (peripheral name);
--                    pos { x, y, z } makes an output a depot (requests "near" a place);
--                    no role means the block's default (containers: storage,
--                    anything else: ignore)
--   controller       the controller's hostname once one was found (no lone mode after)
-- @module logistics

local logistics = {}

logistics.DEFAULT_POLL_SECONDS = 10
logistics.DEFAULT_SHARE = 0.5
logistics.RECOVERY_MARGIN = 0.05
logistics.SIDES = { "top", "bottom", "left", "right", "front", "back" }

--- Directory roles (managed mode, see roles.lua): who may change settings, who may use
-- logistics at all, and the per-node role prefix (items on a node whose role exists are
-- only seen by its members).
logistics.ADMINS = "logistics-admins"
logistics.USERS = "logistics-users"
logistics.NODE_ROLE_PREFIX = "logistics-node-"

local VALID_SIDES = {}
for _, side in ipairs(logistics.SIDES) do
  VALID_SIDES[side] = true
end

-- "logistics-" .. name must still fit a 32-character service record type.
logistics.MAX_NAME_LENGTH = 22

--- Check a controller name ("kitchen").
-- @tparam string name
-- @treturn[1] string The name in lower case.
-- @treturn[2] nil
-- @treturn[2] string error message
function logistics.check_name(name)
  if type(name) ~= "string" or name == "" then
    return nil, "a name is required"
  end
  local clean = name:lower()
  if not clean:match("^[%w_%-]+$") then
    return nil, "names may only use letters, digits, - and _"
  end
  if #clean > logistics.MAX_NAME_LENGTH then
    return nil, "names may be at most " .. logistics.MAX_NAME_LENGTH .. " characters"
  end
  return clean
end

--- Alerts as a history to show: newest first, and only the newest alert of
-- each item marked current (older ones are superseded, e.g. a LOW that was
-- followed by "ok again").
-- @tparam {table...} alerts Oldest first, as the stock computer keeps them.
-- @treturn {table...} Copies, newest first, each with `is_current`.
function logistics.alert_history(alerts)
  local history = {}
  local seen = {}
  for index = #alerts, 1, -1 do
    local alert = alerts[index]
    local copy = {}
    for key, value in pairs(alert) do
      copy[key] = value
    end
    local key = tostring(alert.server) .. "/" .. tostring(alert.item)
    copy.is_current = not seen[key]
    seen[key] = true
    history[#history + 1] = copy
  end
  return history
end

--- Fill in anything missing in a levels config.
-- @tparam table config
-- @treturn table The same table.
function logistics.normalise(config)
  if config.chime == nil then
    config.chime = true
  end
  config.sound = config.sound or { kind = "note", value = "bell", volume = 3 }
  config.watches = config.watches or {}
  config.any_low_outputs = config.any_low_outputs or {}
  return config
end

--- Fill in anything missing in a node config.
-- @tparam table config
-- @treturn table The same table.
function logistics.normalise_node(config)
  config.poll_seconds = config.poll_seconds or logistics.DEFAULT_POLL_SECONDS
  config.storages = config.storages or {}
  return config
end

--- Split an old storage-monitor config into a node config and a levels config.
-- @tparam table old The saved /etc/blockos/storage-monitor table.
-- @treturn table node config
-- @treturn table levels config
function logistics.split_old_config(old)
  local node = logistics.normalise_node({
    poll_seconds = old.poll_seconds,
    storages = old.storages,
  })
  local levels = logistics.normalise({
    chime = old.chime,
    sound = old.sound,
    watches = old.watches,
    any_low_outputs = old.any_low_outputs,
    name = old.name,
  })
  return node, levels
end

------------------------------------------------------------------------------
-- Storage roles (item logistics)
------------------------------------------------------------------------------

--- What an inventory is for:
--   storage   counted; items are sorted into it and requested from it
--   input     emptied into storage automatically
--   output    requested items are delivered here
--   ignore    not counted and never touched (furnaces, machines, trash)
logistics.ROLES = { "storage", "input", "output", "ignore" }
logistics.DEFAULT_ROLE = "storage"
logistics.MAX_LABEL_LENGTH = 32

local VALID_ROLES = {}
for _, role in ipairs(logistics.ROLES) do
  VALID_ROLES[role] = true
end

--- @tparam string role
-- @treturn boolean
function logistics.is_role(role)
  return VALID_ROLES[role] == true
end

--- The role of an inventory: the one set for it, else the block's default.
-- @tparam table config
-- @tparam string handle Peripheral name.
-- @tparam[opt] string default The block's default role (see the source's
--   default_role); "storage" when not given.
-- @treturn string
function logistics.role_of(config, handle, default)
  local entry = config.storages[handle]
  return entry and entry.role or default or logistics.DEFAULT_ROLE
end

--- The name to show for an inventory: its label, else its peripheral name.
-- @tparam table config
-- @tparam string handle
-- @treturn string
function logistics.storage_name(config, handle)
  local entry = config.storages[handle]
  return entry and entry.label or handle
end

--- Check a position { x, y, z } and round it to whole blocks.
-- @param pos
-- @treturn[1] table { x, y, z }
-- @treturn[2] nil
-- @treturn[2] string error message
function logistics.clean_pos(pos)
  if type(pos) ~= "table" then
    return nil, "a position needs x, y and z"
  end
  local x, y, z = tonumber(pos.x), tonumber(pos.y), tonumber(pos.z)
  if not (x and y and z) then
    return nil, "a position needs x, y and z"
  end
  return { x = math.floor(x + 0.5), y = math.floor(y + 0.5), z = math.floor(z + 0.5) }
end

--- Straight-line distance between two positions.
function logistics.distance(a, b)
  local dx, dy, dz = a.x - b.x, a.y - b.y, a.z - b.z
  return math.sqrt(dx * dx + dy * dy + dz * dz)
end

--- Set an inventory's role, label and/or position. A label of "" removes it; a
-- position of false removes it.
-- @tparam table config
-- @tparam string handle
-- @tparam[opt] string role
-- @tparam[opt] string label
-- @tparam[opt] table|boolean pos { x, y, z }, or false to remove it
-- @treturn[1] true
-- @treturn[2] nil
-- @treturn[2] string error message
function logistics.set_storage(config, handle, role, label, pos)
  if role ~= nil and not logistics.is_role(role) then
    return nil, "the role must be one of: " .. table.concat(logistics.ROLES, ", ")
  end
  if label ~= nil and #label > logistics.MAX_LABEL_LENGTH then
    return nil, "labels may be at most " .. logistics.MAX_LABEL_LENGTH .. " characters"
  end
  local clean_pos = nil
  if pos then
    local err
    clean_pos, err = logistics.clean_pos(pos)
    if not clean_pos then
      return nil, err
    end
  end
  local entry = config.storages[handle] or {}
  if pos ~= nil then
    entry.pos = clean_pos or nil
  end
  if role ~= nil then
    -- Stored even when it equals the default: defaults depend on the block.
    entry.role = role
  end
  if label ~= nil then
    entry.label = label ~= "" and label or nil
  end
  config.storages[handle] = next(entry) ~= nil and entry or nil
  return true
end

-- Case-insensitive matching for names typed by people: an exact match wins,
-- otherwise the only partial match; several partial matches are ambiguous.
local function match_one(query, candidates)
  local wanted = query:lower()
  local partial = {}
  for _, candidate in ipairs(candidates) do
    local is_partial = false
    for _, text in ipairs(candidate.names) do
      local lowered = text:lower()
      if lowered == wanted then
        return candidate.value
      end
      is_partial = is_partial or lowered:find(wanted, 1, true) ~= nil
    end
    if is_partial then
      partial[#partial + 1] = candidate
    end
  end
  if #partial == 1 then
    return partial[1].value
  end
  if #partial == 0 then
    return nil, "nothing matches " .. query
  end
  local shown = {}
  for index = 1, math.min(5, #partial) do
    shown[index] = partial[index].names[#partial[index].names]
  end
  return nil, query .. " is ambiguous: " .. table.concat(shown, ", ")
end

--- Find an item by id or (part of) its label, e.g. "iron" or "minecraft:iron_ingot".
-- @tparam table totals [item] = { count, label }
-- @tparam string query
-- @treturn[1] string Item id.
-- @treturn[2] nil
-- @treturn[2] string error message
function logistics.find_item(totals, query)
  local candidates = {}
  for item, found in pairs(totals) do
    candidates[#candidates + 1] = { value = item, names = { item, found.label or item } }
  end
  table.sort(candidates, function(a, b) return a.value < b.value end)
  return match_one(query, candidates)
end

--- Find an inventory by peripheral name or (part of) its label.
-- @tparam table config
-- @tparam {string...} handles Inventories currently found.
-- @tparam string query
-- @treturn[1] string Handle.
-- @treturn[2] nil
-- @treturn[2] string error message
function logistics.find_storage(config, handles, query)
  local candidates = {}
  for _, handle in ipairs(handles) do
    candidates[#candidates + 1] = {
      value = handle,
      names = { handle, logistics.storage_name(config, handle) },
    }
  end
  return match_one(query, candidates)
end

--- Find a block among the rows of several nodes, by peripheral name, label or
-- "node/name" (needed when two nodes have a chest of the same name).
-- @tparam {table...} rows { node, handle, label }
-- @tparam string query
-- @treturn[1] table The row.
-- @treturn[2] nil
-- @treturn[2] string error message
function logistics.find_block(rows, query)
  -- The same peripheral name on two nodes is common (minecraft:chest_0): ask for
  -- node/name instead of picking one.
  local wanted, exact = query:lower(), {}
  for _, row in ipairs(rows) do
    if row.handle:lower() == wanted or tostring(row.label):lower() == wanted then
      exact[#exact + 1] = row
    end
  end
  if #exact > 1 then
    return nil, query .. " is ambiguous: say which node, e.g. " .. exact[1].node .. "/"
      .. exact[1].handle
  end
  local candidates = {}
  for _, row in ipairs(rows) do
    candidates[#candidates + 1] = {
      value = row,
      names = { row.handle, row.label or row.handle, row.node .. "/" .. row.handle },
    }
  end
  return match_one(query, candidates)
end

--- Check a redstone output { target, side }.
-- @treturn[1] true
-- @treturn[2] nil
-- @treturn[2] string error message
function logistics.validate_output(output)
  if type(output) ~= "table" or type(output.target) ~= "string" or output.target == "" then
    return nil, "an output needs a target (computer or a relay)"
  end
  if not VALID_SIDES[output.side] then
    return nil, "an output needs a side: " .. table.concat(logistics.SIDES, ", ")
  end
  return true
end

--- Check and clean a watch before it is stored.
-- @tparam table watch { label, limit, refill_to?, outputs }
-- @treturn[1] table The cleaned watch.
-- @treturn[2] nil
-- @treturn[2] string error message
function logistics.clean_watch(watch)
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
    local ok, err = logistics.validate_output(output)
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
function logistics.recovery_level(watch)
  if watch.refill_to then
    return watch.refill_to
  end
  return watch.limit + math.max(1, math.ceil(watch.limit * logistics.RECOVERY_MARGIN))
end

--- Compare current counts with the watches.
-- @tparam table config
-- @tparam table totals [item] = { count, label } from the storage sources.
-- @tparam[opt] table previous The states from the last call.
-- @treturn table states: [item] = { label, count, limit, is_low }
-- @treturn table changes: { went_low = {item...}, recovered = {item...},
--   cleared = { [item] = state } } (cleared: items unwatched while low, also
--   listed in recovered; they have no entry in states)
function logistics.evaluate(config, totals, previous)
  previous = previous or {}
  local states = {}
  local changes = { went_low = {}, recovered = {}, cleared = {} }
  for item, watch in pairs(config.watches) do
    local found = totals[item]
    local count = found and found.count or 0
    local was_low = previous[item] ~= nil and previous[item].is_low
    local is_low
    if was_low then
      is_low = count < logistics.recovery_level(watch)
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
  -- An item unwatched while low never recovers by itself, so it counts as
  -- recovered once: other computers then clear their notices and reactions.
  for item, old in pairs(previous) do
    if old.is_low and not config.watches[item] then
      changes.recovered[#changes.recovered + 1] = item
      changes.cleared[item] = {
        label = old.label,
        count = old.count,
        limit = old.limit,
        is_low = false,
      }
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
-- @tparam table states From logistics.evaluate.
-- @treturn table [ "target|side" ] = { target, side, is_on }
function logistics.output_states(config, states)
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
function logistics.reaction_outputs(reactions, item_low)
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
function logistics.watch_from_contents(config, totals, share)
  share = share or logistics.DEFAULT_SHARE
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

--- Rows for display, sorted: low items first, then by label.
-- @tparam table states From logistics.evaluate.
-- @treturn {table...} { item, label, count, limit, refill_to, is_low }
function logistics.sorted_rows(states)
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

return logistics
