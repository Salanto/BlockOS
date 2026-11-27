--- A view of the peripheral API that only sees a node's storage network.
--
-- A node has two modems that never mix: the storage modem (its chests and machines)
-- and the main modem (rednet to the controller). Sources get this view instead of
-- `peripheral`, so they never count or move items in a block on the main network,
-- even when that network has inventories too (ports, other nodes' chests). Blocks
-- placed directly against the computer belong to the node as well.
-- @module logistics_scope

local logistics_scope = {}

local SIDES = { "top", "bottom", "left", "right", "front", "back" }

--- Make a scoped view.
-- @tparam[opt] string side The storage modem's side; nil: everything attached.
-- @tparam[opt] table api The peripheral API (tests pass a fake one).
-- @treturn table getNames, isPresent, hasType, getType, wrap (like `peripheral`)
function logistics_scope.new(side, api)
  api = api or peripheral
  if not side then
    return api
  end

  -- The name list is asked for on every wrap and type check of a round; within one
  -- game tick it cannot change, so it is built once per tick.
  local cached, cached_at
  local function names()
    local now = os.clock()
    if cached and cached_at == now then
      return cached
    end
    local list = {}
    local modem = api.wrap(side)
    if modem and modem.getNamesRemote then
      for _, name in ipairs(modem.getNamesRemote()) do
        list[#list + 1] = name
      end
    end
    for _, attached in ipairs(SIDES) do
      if api.isPresent(attached) and not api.hasType(attached, "modem") then
        list[#list + 1] = attached
      end
    end
    cached, cached_at = list, now
    return list
  end

  local function is_inside(name)
    for _, found in ipairs(names()) do
      if found == name then
        return true
      end
    end
    return false
  end

  return {
    getNames = names,
    isPresent = is_inside,
    hasType = function(name, kind)
      if is_inside(name) then
        return api.hasType(name, kind)
      end
      return nil
    end,
    getType = function(name)
      if is_inside(name) then
        return api.getType(name)
      end
      return nil
    end,
    wrap = function(name)
      if is_inside(name) then
        return api.wrap(name)
      end
      return nil
    end,
  }
end

return logistics_scope
