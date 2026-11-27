--- Request handlers of a hub (protocol "blockos.logistics"): what players' tools,
-- boards and programs may ask the controller (or a lone node, from its own keyboard).
--
-- Who may do what follows the module roles (see roles.lua):
--   standalone, or in a domain before `domain setup logistics`: open to everyone
--   managed:  logistics-users    look, request items, find chests, start crafting
--             logistics-admins   also levels, alarms, storage roles, nodes
--             (domain-admins count as logistics admins)
--   a node whose role logistics-node-<node> exists is only seen by its members
--   (its items, chests and moves), e.g. one player's private storage
--   local admin at the hub's own keyboard: always allowed, so a broken role cannot
--   lock everyone out
-- Users are checked with the domain controller on every request.
-- @module logistics_handlers

local rpc = import("rpc")
local logistics = import("logistics")
local logistics_alarms = import("logistics_alarms")

local logistics_handlers = {}

local ITEM = { type = "string", max = 128 }
local ARGS = {
  item = { item = ITEM },
  watch = {
    item = ITEM,
    limit = { type = "number", min = 1 },
    refill_to = { type = "number", min = 0, optional = true }, -- 0 clears it
    label = { type = "string", optional = true, max = 64 },
    outputs = { type = "table", optional = true },
  },
  watch_all = { share = { type = "number", min = 0, optional = true } },
  settings = {
    chime = { type = "boolean", optional = true },
    any_low_outputs = { type = "table", optional = true },
    sound = { type = "table", optional = true },
  },
  -- `storage` and `output` are a peripheral name, (part of) a label, or node/name.
  set_storage = {
    storage = { type = "string", max = 96 },
    role = { type = "string", optional = true, max = 16 },
    label = { type = "string", optional = true, max = 64 },
    pos = { type = "table", optional = true }, -- { x, y, z }: an output becomes a depot
    clear_pos = { type = "boolean", optional = true },
    forget = { type = "boolean", optional = true }, -- drop the entry (missing chests)
  },
  moves = { since = { type = "number", optional = true } },
  -- `item` is an item id or (part of) its name.
  -- `near` { x, y, z }: deliver to the nearest depot (for turtles and pockets).
  request = {
    item = ITEM,
    count = { type = "number", min = 1 },
    output = { type = "string", optional = true, max = 96 },
    near = { type = "table", optional = true },
  },
  depots = { near = { type = "table", optional = true } },
  craft = { item = ITEM, count = { type = "number", min = 1 } },
  -- A node's crafter asks for an ingredient it lacks, to go into one of its machines.
  supply = {
    node = { type = "string", max = 32 },
    item = ITEM,
    count = { type = "number", min = 1 },
    target = { type = "string", max = 64 },
  },
  node = { node = { type = "string", max = 32 } },
}

-- The domain package is optional: without it everything is open (standalone).
local function roles_module()
  local found, roles = pcall(import, "roles")
  return found and roles or nil
end

--- Build the handler table.
-- @tparam table hub From logistics_hub.new.
-- @treturn table handlers
-- @treturn function require_admin(ctx), for handlers added by the caller
function logistics_handlers.new(hub)
  local handlers = {}
  local with_args = rpc.with_args

  local function allows(ctx, role)
    local roles = roles_module()
    if not roles then
      return true
    end
    return roles.allows(ctx, role)
  end

  local function require_user(ctx)
    return allows(ctx, logistics.USERS)
  end

  local function require_admin(ctx)
    local ok, err = allows(ctx, logistics.ADMINS)
    if ok then
      return true
    end
    if ctx.token and rpc.require_user(ctx, { "domain-admins" }) then
      return true
    end
    return nil, err
  end

  -- Which nodes this caller may see: all, unless a node's own role exists and the
  -- caller is not in it.
  local function visibility(ctx)
    local roles = roles_module()
    if not roles or not roles.env.is_joined() or ctx.local_admin then
      return nil
    end
    local groups = nil
    local function in_group(group)
      if groups == nil then
        local user = ctx.token and rpc.require_user(ctx)
        groups = {}
        for _, name in ipairs(user and user.groups or {}) do
          groups[name] = true
        end
      end
      return groups[group] == true
    end
    return function(node)
      local role = logistics.NODE_ROLE_PREFIX .. node
      local info = roles.info(role)
      return info == nil or info.everyone == true or in_group(role)
        or in_group("domain-admins")
    end
  end

  -- Wrap a handler: check access first, then call fn(ctx, args, visible).
  local function user_op(fn)
    return function(ctx, args)
      local ok, err = require_user(ctx)
      if not ok then
        return nil, err
      end
      return fn(ctx, args or {}, visibility(ctx))
    end
  end

  -- Run a change as an admin and save it.
  local function admin_change(ctx, apply)
    local ok, err = require_admin(ctx)
    if not ok then
      return nil, err
    end
    local result, apply_error = apply()
    if not result then
      return nil, apply_error
    end
    local saved, save_error = hub.save()
    if not saved then
      return nil, save_error
    end
    return result
  end

  -- Reading --------------------------------------------------------------

  handlers.status = user_op(function()
    return hub.snapshot()
  end)

  handlers.alerts = user_op(function()
    return hub.alerts
  end)

  handlers.catalog = user_op(function(_, _, visible)
    local craftable = hub.craftable(visible)
    local items = {}
    for item, found in pairs(hub.totals(visible)) do
      items[#items + 1] = {
        item = item,
        label = found.label or item,
        count = found.count,
        nodes = found.nodes,
        is_watched = hub.config.watches[item] ~= nil,
        can_craft = craftable[item] ~= nil,
      }
    end
    table.sort(items, function(a, b) return tostring(a.label) < tostring(b.label) end)
    return items
  end)

  --- The watches with their alarm outputs (for the Alarms tab).
  handlers.watches = user_op(function()
    local watches = {}
    for item, watch in pairs(hub.config.watches) do
      watches[#watches + 1] = {
        item = item,
        label = watch.label or item,
        limit = watch.limit,
        outputs = watch.outputs,
      }
    end
    table.sort(watches, function(a, b) return tostring(a.label) < tostring(b.label) end)
    return { watches = watches, any_low_outputs = hub.config.any_low_outputs }
  end)

  function handlers.outputs(ctx)
    local ok, err = require_admin(ctx)
    if not ok then
      return nil, err
    end
    return hub.list_outputs()
  end

  handlers.nodes = user_op(function(_, _, visible)
    return hub.list_nodes(visible)
  end)

  -- Changing -------------------------------------------------------------

  -- A refill target from a request: missing keeps the old one, 0 clears it.
  local function refill_target(requested, existing)
    if requested == 0 then
      return nil
    end
    return requested or existing
  end

  handlers.watch = with_args(ARGS.watch, function(ctx, args)
    return admin_change(ctx, function()
      local existing = hub.config.watches[args.item] or {}
      local found = hub.totals()[args.item]
      local watch, err = logistics.clean_watch({
        label = args.label or existing.label or (found and found.label) or args.item,
        limit = args.limit,
        refill_to = refill_target(args.refill_to, existing.refill_to),
        outputs = args.outputs or existing.outputs,
      })
      if not watch then
        return nil, err
      end
      hub.config.watches[args.item] = watch
      return true
    end)
  end)

  handlers.unwatch = with_args(ARGS.item, function(ctx, args)
    return admin_change(ctx, function()
      if not hub.config.watches[args.item] then
        return nil, "that item is not watched"
      end
      hub.config.watches[args.item] = nil
      return true
    end)
  end)

  handlers.watch_all = with_args(ARGS.watch_all, function(ctx, args)
    return admin_change(ctx, function()
      local added = logistics.watch_from_contents(hub.config, hub.totals(), args.share)
      return { added = added }
    end)
  end)

  handlers.settings = with_args(ARGS.settings, function(ctx, args)
    return admin_change(ctx, function()
      for _, output in ipairs(args.any_low_outputs or {}) do
        local ok, err = logistics.validate_output(output)
        if not ok then
          return nil, err
        end
      end
      if args.sound then
        local ok, err = logistics_alarms.validate_sound(args.sound)
        if not ok then
          return nil, err
        end
      end
      local config = hub.config
      config.sound = args.sound or config.sound
      if args.chime ~= nil then
        config.chime = args.chime
      end
      config.any_low_outputs = args.any_low_outputs or config.any_low_outputs
      return true
    end)
  end)

  --- Play the alarm sound now, so admins can hear what they picked.
  function handlers.test_sound(ctx)
    local ok, err = require_admin(ctx)
    if not ok then
      return nil, err
    end
    return logistics_alarms.chime(hub.config.sound)
  end

  handlers.forget_node = with_args(ARGS.node, function(ctx, args)
    local ok, err = require_admin(ctx)
    if not ok then
      return nil, err
    end
    return hub.forget_node(args.node)
  end)

  -- Storage and requests -------------------------------------------------

  handlers.storages = user_op(function(_, _, visible)
    return hub.list_storages(visible)
  end)

  --- Moves newer than `since` (for the map's animations), and the newest seq.
  handlers.moves = with_args(ARGS.moves, user_op(function(_, args, visible)
    local since = args.since or 0
    local newer = {}
    for _, move in ipairs(hub.moves) do
      if move.seq > since and (visible == nil or visible(move.node)) then
        newer[#newer + 1] = move
      end
    end
    -- `log` changes when the hub restarts: seqs then start again at 1.
    return { log = hub.move_log, seq = hub.move_seq, moves = newer }
  end))

  -- Crafting --------------------------------------------------------------

  handlers.jobs = user_op(function(_, _, visible)
    return hub.jobs(visible)
  end)

  --- Items some node can craft (also ones not in storage at all).
  handlers.recipes = user_op(function(_, _, visible)
    local rows = {}
    for item, node in pairs(hub.craftable(visible)) do
      local found = hub.totals(visible)[item]
      rows[#rows + 1] = { item = item, node = node, label = found and found.label or item,
        count = found and found.count or 0 }
    end
    table.sort(rows, function(a, b) return tostring(a.label) < tostring(b.label) end)
    return rows
  end)

  handlers.craft = with_args(ARGS.craft, user_op(function(_, args, visible)
    -- Craftable items may have none in storage yet: look among the recipes too.
    local names = {}
    for item, found in pairs(hub.totals(visible)) do
      names[item] = { label = found.label }
    end
    for item in pairs(hub.craftable(visible)) do
      names[item] = names[item] or { label = item }
    end
    local item, err = logistics.find_item(names, args.item)
    if not item then
      return nil, err
    end
    local result, craft_error = hub.craft(item, math.floor(args.count), visible)
    if not result then
      return nil, craft_error
    end
    result.label = names[item].label
    return result
  end))

  -- From a node's crafter: a joined computer in a domain, anyone without one.
  handlers.supply = with_args(ARGS.supply, function(ctx, args)
    local found, domain = pcall(import, "domain")
    if found and domain.is_joined() and not ctx.local_admin then
      local computer, err = rpc.require_computer(ctx)
      if not computer then
        return nil, err
      end
    end
    -- Private nodes (their role exists) never give to another node's crafting: one
    -- player's recipe must not empty another's storage.
    local roles = roles_module()
    local function may_give(node)
      if not (roles and roles.env.is_joined()) then
        return true
      end
      return roles.info(logistics.NODE_ROLE_PREFIX .. node) == nil
    end
    return hub.supply(args.node, args.item, math.floor(args.count), args.target, may_give)
  end)

  --- Output chests with a position, nearest first when `near` is given.
  handlers.depots = with_args(ARGS.depots, user_op(function(_, args, visible)
    local near = args.near and logistics.clean_pos(args.near)
    return hub.depots(near, visible)
  end))

  handlers.find_start = user_op(function(_, _, visible)
    return hub.find_start(visible)
  end)

  handlers.find_finish = user_op(function(_, args, visible)
    return hub.find_finish(visible, type(args.id) == "string" and args.id or nil)
  end)

  handlers.set_storage = with_args(ARGS.set_storage, function(ctx, args)
    local visible = visibility(ctx)
    return admin_change(ctx, function()
      local row, err = logistics.find_block(hub.list_storages(visible), args.storage)
      if not row then
        return nil, err
      end
      if args.role ~= nil and not logistics.is_role(args.role) then
        return nil, "the role must be one of: " .. table.concat(logistics.ROLES, ", ")
      end
      if args.pos and not logistics.clean_pos(args.pos) then
        return nil, "a position needs x, y and z"
      end
      return hub.set_storage(row, {
        role = args.role,
        label = args.label,
        pos = args.pos,
        clear_pos = args.clear_pos,
        forget = args.forget,
      })
    end)
  end)

  handlers.request = with_args(ARGS.request, user_op(function(_, args, visible)
    local totals = hub.totals(visible)
    local item, item_error = logistics.find_item(totals, args.item)
    if not item then
      return nil, item_error
    end
    local near = nil
    if args.near then
      local near_error
      near, near_error = logistics.clean_pos(args.near)
      if not near then
        return nil, near_error
      end
    end
    local output = nil
    if args.output then
      local output_error
      output, output_error = logistics.find_block(hub.list_storages(visible), args.output)
      if not output then
        return nil, output_error
      end
    end
    local result, request_error = hub.request(item, math.floor(args.count), output, visible,
      near)
    if not result then
      return nil, request_error
    end
    result.item = item
    result.label = totals[item] and totals[item].label or item
    return result
  end))

  return handlers, require_admin
end

return logistics_handlers
