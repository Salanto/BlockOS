--- The player locator's handlers (protocol "blockos.players", see players.lua), kept apart
-- from the service so tests can pass a stub detector.
-- @module player_locator

local rpc = import("rpc")
local players = import("players")

local player_locator = {}

--- Build the handlers.
-- @tparam function find_detector function() -> the Player Detector peripheral or nil
-- @treturn table { [op] = function(ctx, args) }
function player_locator.handlers(find_detector)
  local handlers = {}

  local function detector()
    local found = find_detector()
    if not found then
      return nil, "the player locator has no Player Detector"
    end
    return found
  end

  handlers.where = rpc.with_args(players.ARGS.where, function(_, args)
    local found, err = detector()
    if not found then
      return nil, err
    end
    local ok, pos = pcall(found.getPlayerPos, args.name)
    if not ok or type(pos) ~= "table" or type(pos.x) ~= "number" then
      return nil, args.name .. " not found"
    end
    return { name = args.name, x = pos.x, y = pos.y, z = pos.z, dimension = pos.dimension }
  end)

  function handlers.online()
    local found, err = detector()
    if not found then
      return nil, err
    end
    local ok, names = pcall(found.getOnlinePlayers)
    if not ok or type(names) ~= "table" then
      return nil, "the Player Detector did not answer"
    end
    return names
  end

  return handlers
end

return player_locator
