--- The hub's routing: storages, requests, depots, crossings between nodes, supplies.
-- Part of the hub (see logistics_hub): attached to a hub when it is made.
-- @module logistics_hub_routing

local logistics = import("logistics")

local logistics_hub_routing = {}

--- Add this part's functions to a hub.
-- @tparam table hub
-- @tparam table internal What the hub shares with its parts: options, config, log,
--   count_on, is_stale, live_names, record_crossing.
function logistics_hub_routing.attach(hub, internal)
  local options, log = internal.options, internal.log
  local count_on, is_stale = internal.count_on, internal.is_stale
  local live_names, record_crossing = internal.live_names, internal.record_crossing

  ---------------------------------------------------------------------------
  -- Storage and requests
  ---------------------------------------------------------------------------

  --- Every block of the visible nodes, with a node column, sorted by node and label.
  function hub.list_storages(visible)
    local rows = {}
    for _, name in ipairs(hub.node_names(visible)) do
      for _, block in ipairs(hub.nodes[name].report.blocks or {}) do
        local row = { node = name }
        for key, value in pairs(block) do
          row[key] = value
        end
        if row.role == "port" and options.port_status then
          row.port = options.port_status(name, row.handle)
        end
        rows[#rows + 1] = row
      end
    end
    table.sort(rows, function(a, b)
      if a.node ~= b.node then
        return a.node < b.node
      end
      return tostring(a.label) < tostring(b.label)
    end)
    return rows
  end

  local function has_output(name)
    for _, block in ipairs(hub.nodes[name].report.blocks or {}) do
      if block.role == "output" and not block.is_missing then
        return true
      end
    end
    return false
  end

  -- The node to take an item from when no output was named: the one with the most of
  -- it that has an output chest.
  local function pick_node(item, visible)
    local best, best_count = nil, 0
    local holding = nil
    for _, name in ipairs(live_names(visible)) do
      local count = count_on(hub.nodes[name], item)
      if count > 0 then
        holding = holding or name
        if count > best_count and has_output(name) then
          best, best_count = name, count
        end
      end
    end
    if best then
      return best
    end
    if holding then
      return nil, "node " .. holding .. " has it but no output chest: give one the "
        .. "'output' role in the Storage tab"
    end
    if (hub.totals(visible)[item] or {}).count then
      return nil, "only nodes that are not answering have it (unloaded chunk?)"
    end
    return nil, "none in storage"
  end

  --- Output chests with a position (depots), nearest first when `near` is given.
  -- @tparam[opt] table near { x, y, z }
  -- @tparam[opt] function visible
  -- @treturn {table...} { node, handle, label, pos, distance? }
  function hub.depots(near, visible)
    local depots = {}
    for _, name in ipairs(live_names(visible)) do
      for _, block in ipairs(hub.nodes[name].report.blocks or {}) do
        if block.role == "output" and block.pos and not block.is_missing then
          depots[#depots + 1] = {
            node = name,
            handle = block.handle,
            label = block.label or block.handle,
            pos = block.pos,
            distance = near and logistics.distance(near, block.pos) or nil,
          }
        end
      end
    end
    if near then
      table.sort(depots, function(a, b) return a.distance < b.distance end)
    end
    return depots
  end

  -- The depot for a request near a place: the nearest whose node has enough of the
  -- item, else the nearest whose node has some.
  local function pick_depot(item, count, near, visible)
    local fallback = nil
    for _, depot in ipairs(hub.depots(near, visible)) do
      local stored = count_on(hub.nodes[depot.node], item)
      if stored >= count then
        return depot
      end
      if stored > 0 and not fallback then
        fallback = depot
      end
    end
    if fallback then
      return fallback
    end
    return nil, "no depot has any: give an output chest next to the items a position "
      .. "(logistics storage pos)"
  end

  -- The counts drop at once, so the Catalog and a second request do not see items that
  -- already left (the next report corrects any difference).
  -- The counts drop at once until the node's report includes the move (`seq`: the
  -- first report that does; without one, the next report).
  local function took(name, item, moved, seq)
    local entry = hub.nodes[name]
    if entry and moved > 0 then
      entry.pending = entry.pending or {}
      entry.pending[#entry.pending + 1] = { item = item, count = moved,
        seq = seq or ((entry.report.seq or 0) + 1) }
    end
  end

  local function stored_on(name, item)
    return count_on(hub.nodes[name], item)
  end

  -- The node with the most of an item, other than `except`.
  local function richest(item, visible, except)
    local best, best_count = nil, 0
    for _, name in ipairs(live_names(visible)) do
      local count = stored_on(name, item)
      if name ~= except and count > best_count then
        best, best_count = name, count
      end
    end
    return best
  end

  -- Where to deliver when nothing was named. With ports, any node with an output will
  -- do when the nodes holding the item have none.
  local function pick_target(item, count, near, visible)
    if near then
      local depot, err = pick_depot(item, count, near, visible)
      if not depot and options.transfer then
        depot = hub.depots(near, visible)[1]
      end
      if not depot then
        return nil, nil, err
      end
      return depot.node, depot
    end
    local name, err = pick_node(item, visible)
    if not name and options.transfer and richest(item, visible) then
      for _, candidate in ipairs(live_names(visible)) do
        if has_output(candidate) then
          return candidate
        end
      end
    end
    return name, nil, err
  end

  --- Deliver items to an output chest. With ports (the controller's `transfer`),
  -- what the output's node lacks comes from the node with the most of it.
  -- @tparam string item Item id.
  -- @tparam number count
  -- @tparam[opt] table output A row from list_storages (its node delivers); default: the
  --   node with the most of the item that has an output.
  -- @tparam[opt] function visible Which nodes the caller may use.
  -- @tparam[opt] table near { x, y, z }: deliver to the nearest depot (output chest
  --   with a position) instead
  -- @treturn[1] table { moved, output, output_label?, pos?, node, from? }
  -- @treturn[2] nil
  -- @treturn[2] string error message
  function hub.request(item, count, output, visible, near)
    local name, err
    if output then
      name = output.node
    else
      name, output, err = pick_target(item, count, near, visible)
    end
    if not name then
      return nil, err
    end
    local entry = hub.nodes[name]
    if not entry then
      return nil, "no node called " .. tostring(name)
    end
    if is_stale(entry) then
      return nil, "node " .. name .. " is not answering (unloaded chunk?)"
    end
    local transfer = options.transfer
    local handle = output and output.handle
    local have = stored_on(name, item)
    local moved, source = 0, nil

    if have > 0 or not transfer then
      local wanted = transfer and math.min(count, have) or count
      local result, request_error = entry.proxy.request(item, wanted, handle)
      if not result then
        return nil, request_error
      end
      moved = result.moved or 0
      handle = handle or result.output
      took(name, item, moved, result.seq)
    end

    if transfer and moved < count then
      source = richest(item, visible, name)
      if source then
        local crossed, cross_error = transfer(hub.nodes[source], entry, item, count - moved, handle)
        if crossed then
          record_crossing(source, name, item, crossed.moved or 0)
          took(source, item, crossed.moved or 0, crossed.seq)
          moved = moved + (crossed.moved or 0)
          handle = handle or crossed.output
        elseif moved == 0 then
          return nil, cross_error
        end
      elseif moved == 0 then
        return nil, "none in storage"
      end
    end

    return {
      moved = moved,
      output = handle,
      node = name,
      from = source,
      output_label = output and output.label,
      pos = output and output.pos,
    }
  end

  --- Change a block's role, label or position (or forget a missing one) on its node.
  -- @tparam table row From list_storages.
  -- @tparam table change { role?, label?, pos?, clear_pos?, forget? }
  function hub.set_storage(row, change)
    local entry = hub.nodes[row.node]
    if not entry then
      return nil, "no node called " .. tostring(row.node)
    end
    local result, err = entry.proxy.set_storage({
      storage = row.handle,
      role = change.role,
      label = change.label,
      pos = change.pos,
      clear_pos = change.clear_pos,
      forget = change.forget,
    })
    if not result then
      return nil, err
    end
    -- Show the change at once; the next report confirms it.
    for index, block in ipairs(entry.report.blocks or {}) do
      if block.handle == row.handle then
        if change.forget then
          table.remove(entry.report.blocks, index)
        else
          block.role = change.role or block.role
          if change.clear_pos then
            block.pos = nil
          elseif change.pos then
            block.pos = logistics.clean_pos(change.pos)
          end
          if change.label then
            block.label = change.label ~= "" and change.label or block.handle
          end
        end
        break
      end
    end
    result.node = row.node
    return result
  end

  --- Find a chest, step 1: every visible node pauses sorting and remembers its blocks.
  -- @treturn string The search's id (find_finish needs it: searches may overlap).
  function hub.find_start(visible)
    local id = string.format("f%d-%d", math.random(0, 0x7fffffff), os.epoch("utc"))
    for _, name in ipairs(live_names(visible)) do
      local ok, err = hub.nodes[name].proxy.find_start(id)
      if not ok then
        log("find on %s: %s", name, tostring(err))
      end
    end
    return { id = id }
  end

  --- Find a chest, step 2: the blocks whose contents changed, on any visible node.
  function hub.find_finish(visible, id)
    local changed = {}
    for _, name in ipairs(live_names(visible)) do
      for _, block in ipairs(hub.nodes[name].proxy.find_finish(id) or {}) do
        changed[#changed + 1] = { node = name, handle = block.handle, label = block.label }
      end
    end
    return changed
  end

  --- Bring an ingredient from other nodes into a machine of `node` (asked by its
  -- crafter when its own storage lacks it). Needs ports.
  -- @tparam[opt] function visible Which nodes may give (not other players' private
  --   nodes).
  function hub.supply(node, item, count, target, visible)
    local entry = hub.nodes[node]
    if not entry then
      return nil, "no node called " .. tostring(node)
    end
    if not options.transfer then
      return nil, "items cannot cross between nodes here"
    end
    local source = richest(item, visible, node)
    if not source then
      return nil, "no other node (that may share) has " .. item
    end
    local result, err = options.transfer(hub.nodes[source], entry, item, count, target)
    if result then
      record_crossing(source, node, item, result.moved or 0)
      took(source, item, result.moved or 0, result.seq)
    end
    return result, err
  end
end

return logistics_hub_routing
