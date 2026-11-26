--- Request handlers of a stock computer (protocol "blockos.stock").
--
-- Every stock computer decides who may reach it (its access list; open to
-- everyone by default, "*" meaning everyone):
--   viewers          status, catalog, alerts, storages, moves, request (taking items
--                    out is for everyone who may look: friends only)
--   admins           everything, including watches, alarms, storage roles and
--                    the access list
--   computers        status and alerts, headless (e.g. a board elsewhere)
--   domain-admins    always admins
--   local admin      at this computer's own keyboard: always admin, so a
--                    mistake in the list cannot lock everyone out
-- Users are checked with the domain controller on every request.
-- @module stock_handlers

local rpc = import("rpc")
local stock = import("stock")
local stock_alarms = import("stock_alarms")

local stock_handlers = {}

local ITEM = { type = "string", max = 128 }
local NAMES = { type = "table", optional = true }
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
    poll_seconds = { type = "number", min = 2, optional = true },
    chime = { type = "boolean", optional = true },
    any_low_outputs = { type = "table", optional = true },
    sound = { type = "table", optional = true },
  },
  set_access = { admins = NAMES, viewers = NAMES, computers = NAMES },
  -- `storage` and `output` are a peripheral name or (part of) a label.
  set_storage = {
    storage = { type = "string", max = 64 },
    role = { type = "string", optional = true, max = 16 },
    label = { type = "string", optional = true, max = 64 },
  },
  moves = { since = { type = "number", optional = true } },
  -- `item` is an item id or (part of) its name.
  request = {
    item = ITEM,
    count = { type = "number", min = 1 },
    output = { type = "string", optional = true, max = 64 },
  },
}

--- Build the handler table.
-- @tparam table monitor The running monitor:
--   config        the config table (changed in place)
--   save()        persist the config; true or nil, err
--   snapshot()    { title, updated, rows, sources }
--   totals        latest [item] = { count, label }
--   alerts        recent alert payloads, newest last
--   list_outputs()  redstone targets that can be chosen
--   inventories   from the last read: { handle, role, source, items? }
--   list_storages()  every inventory with role, label and fill
--   request(item, count, output?)  deliver items (see stock_logistics)
-- @treturn table
function stock_handlers.new(monitor)
  local handlers = {}
  local with_args = rpc.with_args

  -- "admin", "viewer", or nil and why not.
  local function level_of(ctx)
    if ctx.local_admin then
      return "admin"
    end
    if not ctx.token then
      -- No login (or no domain at all): fine for looking, if viewers are open.
      if stock.is_open(monitor.config.access.viewers) then
        return "viewer"
      end
      return nil, rpc.LOGIN_REQUIRED
    end
    local user, err = rpc.require_user(ctx)
    if not user then
      return nil, err
    end
    local level = stock.access_level(monitor.config, user)
    if not level then
      return nil, rpc.PERMISSION_DENIED
    end
    return level
  end

  local function require_admin(ctx)
    local level, err = level_of(ctx)
    if level ~= "admin" then
      return nil, err or rpc.PERMISSION_DENIED
    end
    return true
  end

  local function require_viewer(ctx)
    local level, err = level_of(ctx)
    if not level then
      return nil, err
    end
    return true
  end

  -- Users need to be viewers; a request without a user may come from a listed
  -- computer (headless boards, alert receivers).
  local function require_viewer_or_computer(ctx)
    if ctx.token or ctx.local_admin then
      return require_viewer(ctx)
    end
    if stock.is_open(monitor.config.access.computers) then
      return true
    end
    local computer, err = rpc.require_computer(ctx)
    if not computer then
      return nil, err
    end
    if not stock.is_computer_allowed(monitor.config, computer.hostname) then
      return nil, rpc.PERMISSION_DENIED
    end
    return true
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
    local saved, save_error = monitor.save()
    if not saved then
      return nil, save_error
    end
    return result
  end

  -- Reading --------------------------------------------------------------

  function handlers.status(ctx)
    local ok, err = require_viewer_or_computer(ctx)
    if not ok then
      return nil, err
    end
    return monitor.snapshot()
  end

  function handlers.alerts(ctx)
    local ok, err = require_viewer_or_computer(ctx)
    if not ok then
      return nil, err
    end
    return monitor.alerts
  end

  function handlers.catalog(ctx)
    local ok, err = require_viewer(ctx)
    if not ok then
      return nil, err
    end
    local items = {}
    for item, found in pairs(monitor.totals) do
      items[#items + 1] = {
        item = item,
        label = found.label or item,
        count = found.count,
        is_watched = monitor.config.watches[item] ~= nil,
      }
    end
    table.sort(items, function(a, b) return tostring(a.label) < tostring(b.label) end)
    return items
  end

  --- The watches with their alarm outputs (for the Alarms tab).
  function handlers.watches(ctx)
    local ok, err = require_viewer(ctx)
    if not ok then
      return nil, err
    end
    local watches = {}
    for item, watch in pairs(monitor.config.watches) do
      watches[#watches + 1] = {
        item = item,
        label = watch.label or item,
        limit = watch.limit,
        outputs = watch.outputs,
      }
    end
    table.sort(watches, function(a, b) return tostring(a.label) < tostring(b.label) end)
    return { watches = watches, any_low_outputs = monitor.config.any_low_outputs }
  end

  function handlers.outputs(ctx)
    local ok, err = require_admin(ctx)
    if not ok then
      return nil, err
    end
    return monitor.list_outputs()
  end

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
      local existing = monitor.config.watches[args.item] or {}
      local found = monitor.totals[args.item]
      local watch, err = stock.clean_watch({
        label = args.label or existing.label or (found and found.label) or args.item,
        limit = args.limit,
        refill_to = refill_target(args.refill_to, existing.refill_to),
        outputs = args.outputs or existing.outputs,
      })
      if not watch then
        return nil, err
      end
      monitor.config.watches[args.item] = watch
      return true
    end)
  end)

  handlers.unwatch = with_args(ARGS.item, function(ctx, args)
    return admin_change(ctx, function()
      if not monitor.config.watches[args.item] then
        return nil, "that item is not watched"
      end
      monitor.config.watches[args.item] = nil
      return true
    end)
  end)

  handlers.watch_all = with_args(ARGS.watch_all, function(ctx, args)
    return admin_change(ctx, function()
      local added = stock.watch_from_contents(monitor.config, monitor.totals, args.share)
      return { added = added }
    end)
  end)

  handlers.settings = with_args(ARGS.settings, function(ctx, args)
    return admin_change(ctx, function()
      for _, output in ipairs(args.any_low_outputs or {}) do
        local ok, err = stock.validate_output(output)
        if not ok then
          return nil, err
        end
      end
      if args.sound then
        local ok, err = stock_alarms.validate_sound(args.sound)
        if not ok then
          return nil, err
        end
      end
      local config = monitor.config
      config.sound = args.sound or config.sound
      config.poll_seconds = args.poll_seconds or config.poll_seconds
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
    return stock_alarms.chime(monitor.config.sound)
  end

  function handlers.access(ctx)
    local ok, err = require_admin(ctx)
    if not ok then
      return nil, err
    end
    return monitor.config.access
  end

  handlers.set_access = with_args(ARGS.set_access, function(ctx, args)
    return admin_change(ctx, function()
      local access = monitor.config.access
      access.admins = args.admins or access.admins
      access.viewers = args.viewers or access.viewers
      access.computers = args.computers or access.computers
      return true
    end)
  end)

  -- Logistics ------------------------------------------------------------

  local function inventory_handles()
    local handles = {}
    for _, inventory in ipairs(monitor.inventories or {}) do
      handles[#handles + 1] = inventory.handle
    end
    return handles
  end

  function handlers.storages(ctx)
    local ok, err = require_viewer(ctx)
    if not ok then
      return nil, err
    end
    return monitor.list_storages()
  end

  --- Moves newer than `since` (for the map's animations), and the newest seq.
  handlers.moves = with_args(ARGS.moves, function(ctx, args)
    local ok, err = require_viewer(ctx)
    if not ok then
      return nil, err
    end
    local since = args.since or 0
    local newer = {}
    for _, move in ipairs(monitor.moves or {}) do
      if move.seq > since then
        newer[#newer + 1] = move
      end
    end
    return { seq = monitor.move_seq or 0, moves = newer }
  end)

  handlers.set_storage = with_args(ARGS.set_storage, function(ctx, args)
    return admin_change(ctx, function()
      local handle, err = stock.find_storage(monitor.config, inventory_handles(), args.storage)
      if not handle then
        return nil, err
      end
      local ok, set_error = stock.set_storage(monitor.config, handle, args.role, args.label)
      if not ok then
        return nil, set_error
      end
      return { storage = handle }
    end)
  end)

  handlers.request = with_args(ARGS.request, function(ctx, args)
    local ok, err = require_viewer(ctx)
    if not ok then
      return nil, err
    end
    local item, item_error = stock.find_item(monitor.totals, args.item)
    if not item then
      return nil, item_error
    end
    local output = nil
    if args.output then
      local output_error
      output, output_error = stock.find_storage(monitor.config, inventory_handles(), args.output)
      if not output then
        return nil, output_error
      end
    end
    local result, request_error = monitor.request(item, math.floor(args.count), output)
    if not result then
      return nil, request_error
    end
    result.item = item
    result.label = monitor.totals[item] and monitor.totals[item].label or item
    return result
  end)

  return handlers
end

return stock_handlers
