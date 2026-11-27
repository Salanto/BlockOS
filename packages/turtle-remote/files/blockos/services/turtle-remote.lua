-- turtle-remote service: lets logged-in domain users drive this turtle over
-- rednet (protocol "blockos.remote"), e.g. with `remote <turtle>` on a PC.
--
-- The one service allowed to move, dig and select (see CLAUDE.md, Device
-- rules): driving is its whole purpose, and it only acts on a driver's request.
-- Standalone it is open (friends only); in a domain it needs a domain user (and the
-- turtle-drivers role in managed mode).

local function run(ctx)
  local rpc = import("rpc")
  local turtle_remote = import("turtle_remote")
  rpc.serve(turtle_remote.PROTOCOL, turtle_remote.handlers(turtle, ctx.log))
end

return {
  name = "turtle-remote",
  description = "Remote control for this turtle",
  -- domain-client installs the login validator rpc.require_user relies on.
  after = { "net", "domain-client" },
  restart = "on-failure",
  condition = function() return blockos.device.kind() == "turtle" end,
  run = run,
}
