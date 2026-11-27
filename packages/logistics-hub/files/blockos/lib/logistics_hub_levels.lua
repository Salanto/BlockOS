--- The hub's levels: watched items against the totals, alarms, and keep-stocked crafting.
-- Part of the hub (see logistics_hub): attached to a hub when it is made.
-- @module logistics_hub_levels

local logistics = import("logistics")
local logistics_alarms = import("logistics_alarms")
local logistics_hub = import("logistics_hub")

local logistics_hub_levels = {}

--- Add this part's functions to a hub.
-- @tparam table hub
-- @tparam table internal What the hub shares with its parts: options, config, log,
--   count_on, is_stale, live_names, record_crossing.
function logistics_hub_levels.attach(hub, internal)
  local options, config, log = internal.options, internal.config, internal.log
  local live_names = internal.live_names

  ---------------------------------------------------------------------------
  -- Levels
  ---------------------------------------------------------------------------

  ---------------------------------------------------------------------------
  -- Crafting (nodes with logistics-crafting report their recipes and jobs)
  ---------------------------------------------------------------------------

  --- The node that can craft an item, if any.
  function hub.crafter_for(item, visible)
    for _, name in ipairs(live_names(visible)) do
      local crafting = hub.nodes[name].report.crafting
      for _, craftable in ipairs(crafting and crafting.recipes or {}) do
        if craftable == item then
          return name
        end
      end
    end
    return nil
  end

  --- Every item some node can craft: [item] = node.
  function hub.craftable(visible)
    local items = {}
    for _, name in ipairs(hub.node_names(visible)) do
      local crafting = hub.nodes[name].report.crafting
      for _, item in ipairs(crafting and crafting.recipes or {}) do
        items[item] = items[item] or name
      end
    end
    return items
  end

  --- Crafting jobs of every node (running, waiting, and the last few finished).
  function hub.jobs(visible)
    local rows = {}
    for _, name in ipairs(hub.node_names(visible)) do
      local crafting = hub.nodes[name].report.crafting
      for _, job in ipairs(crafting and crafting.jobs or {}) do
        local row = { node = name }
        for key, value in pairs(job) do
          row[key] = value
        end
        rows[#rows + 1] = row
      end
    end
    return rows
  end

  local function has_open_job(name, item)
    local crafting = hub.nodes[name].report.crafting
    for _, job in ipairs(crafting and crafting.jobs or {}) do
      local is_open = job.state == "queued" or job.state == "running" or job.state == "waiting"
      if job.item == item and is_open then
        return true
      end
    end
    return false
  end

  --- Ask the node with the recipe to craft an item.
  function hub.craft(item, count, visible)
    local name = hub.crafter_for(item, visible)
    if not name then
      return nil, "no node has a recipe for " .. item
    end
    local proxy = hub.nodes[name].proxy
    if not proxy.craft then
      return nil, "node " .. name .. " cannot be asked to craft"
    end
    local result, err = proxy.craft(item, count)
    if not result then
      return nil, err
    end
    result.node = name
    return result
  end

  -- Did the node's last job for this item fail? (Then wait longer before asking.)
  local function failed_last(name, item)
    local crafting = hub.nodes[name].report.crafting
    for _, job in ipairs(crafting and crafting.jobs or {}) do
      if job.item == item then
        return job.state == "failed"
      end
    end
    return false
  end

  -- Are the ingredients of one run in storage somewhere? (Nodes report what each
  -- recipe needs.)
  local function has_ingredients(name, item)
    local crafting = hub.nodes[name].report.crafting
    local needs = crafting and crafting.needs and crafting.needs[item]
    local totals = hub.totals()
    for ingredient, count in pairs(needs or {}) do
      if ((totals[ingredient] or {}).count or 0) < count then
        return false
      end
    end
    return true
  end

  -- Keep stocked: a low watched item that a node can craft is crafted up to its refill
  -- target (or just above the limit), unless a job for it is already open, the
  -- ingredients are missing, or the last job failed a short while ago.
  local function request_crafts(states)
    local now = logistics_hub.env.clock()
    for item, state in pairs(states) do
      local name = state.is_low and hub.crafter_for(item)
      local asked = hub.craft_asked[item]
      local wait = (name and failed_last(name, item)) and logistics_hub.CRAFT_BACKOFF_SECONDS
        or logistics_hub.CRAFT_RETRY_SECONDS
      local is_due = not asked or now - asked >= wait
      if name and is_due and not has_open_job(name, item) and has_ingredients(name, item) then
        local watch = config.watches[item]
        local wanted = logistics.recovery_level(watch) - state.count
        hub.craft_asked[item] = now
        local defer = options.defer or function(job) job() end
        defer(function()
          local result, err = hub.craft(item, math.max(1, wanted))
          if not result then
            log("crafting %s on %s: %s", item, name, tostring(err))
          end
        end)
      end
    end
  end

  --- Compare the merged totals with the watched items and raise alarms.
  function hub.check_levels()
    hub.levels_due, hub.levels_at = false, logistics_hub.env.clock()
    local states, changes = logistics.evaluate(config, hub.totals(), hub.states)
    hub.states = states
    request_crafts(states)
    hub.updated = logistics_hub.env.time()

    local wanted = logistics.output_states(config, states)
    hub.applied_outputs = logistics_alarms.apply_redstone(wanted, hub.applied_outputs)
    for _, item in ipairs(changes.went_low) do
      log("%s is low: %d of %d", states[item].label, states[item].count,
        states[item].limit)
    end
    if #changes.went_low > 0 and config.chime then
      logistics_alarms.chime(config.sound)
    end
    local sent = logistics_alarms.send_alerts(options.hostname, states, changes,
      logistics_alarms.EVERYONE)
    for _, alert in ipairs(sent) do
      -- The history shows when it happened (in-game time); not sent on the wire.
      local entry = { time = hub.updated }
      for key, value in pairs(alert) do
        entry[key] = value
      end
      hub.alerts[#hub.alerts + 1] = entry
      if #hub.alerts > logistics_hub.MAX_ALERTS then
        table.remove(hub.alerts, 1)
      end
    end
  end

  --- Nobody is counting any more: switch lamps and farms off rather than leave them.
  function hub.stop()
    logistics_alarms.apply_redstone({}, hub.applied_outputs)
    hub.applied_outputs = {}
  end

  function hub.snapshot()
    local sources = 0
    for _, entry in pairs(hub.nodes) do
      sources = sources + (entry.report.sources or 0)
    end
    return {
      title = options.title or "Logistics",
      updated = hub.updated,
      rows = logistics.sorted_rows(hub.states),
      sources = sources,
      nodes = #hub.node_names(),
    }
  end

  hub.list_outputs = logistics_alarms.list_outputs
end

return logistics_hub_levels
