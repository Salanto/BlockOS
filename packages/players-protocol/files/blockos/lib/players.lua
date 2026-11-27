--- Where players are: the protocol and its client (protocol "blockos.players").
--
-- A computer with an Advanced Peripherals Player Detector runs player-locator, which
-- answers for every player (the server's detector range decides how far). It is found
-- through the domain service record "players", else by rednet name. Open to every
-- computer and player: we only play with friends, and a turtle following someone needs
-- it without a login.
--
-- rpc:
--   where { name }   -> { name, x, y, z, dimension? } or nil, "not found"
--   online           -> { name... }
-- @module players

local rpc = import("rpc")

local players = {}

players.PROTOCOL = "blockos.players"
players.SERVICE_TYPE = "players"

local NAME = { type = "string", max = 32 }

--- Argument schemas (see wire.validate).
players.ARGS = {
  where = { name = NAME },
}

local function call(op, args)
  local id = import("discovery").find(players.SERVICE_TYPE, players.PROTOCOL)
  if not id then
    return nil, "no player locator found (a computer with a Player Detector and player-locator)"
  end
  return rpc.call(id, players.PROTOCOL, op, args, { timeout = 2, retries = 1 })
end

--- Where a player is.
-- @tparam string name
-- @treturn[1] table { name, x, y, z, dimension? }
-- @treturn[2] nil
-- @treturn[2] string why not
function players.where(name)
  return call("where", { name = name })
end

--- Who is online.
-- @treturn[1] {string...}
-- @treturn[2] nil
-- @treturn[2] string why not
function players.online()
  return call("online")
end

return players
