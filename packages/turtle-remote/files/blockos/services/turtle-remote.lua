-- turtle-remote service: lets logged-in domain users drive this turtle over
-- rednet (protocol "blockos.remote"), e.g. with `remote <turtle>` on a PC.
--
-- The one service allowed to move, dig and select (see CLAUDE.md, Device
-- rules): driving is its whole purpose, and only a domain user's request
-- makes it act. It runs only on turtles that are in a domain.

local function run(ctx)
  local domain = import("domain")
  local rpc = import("rpc")
  local turtle_remote = import("turtle_remote")

  if not domain.is_joined() then
    ctx.log.info("not in a domain: remote control is off")
    return
  end
  rpc.serve(turtle_remote.PROTOCOL, turtle_remote.handlers(turtle, ctx.log))
end

return {
  name = "turtle-remote",
  description = "Remote control for this turtle (domain users)",
  -- domain-client installs the login validator rpc.require_user relies on.
  after = { "net", "domain-client" },
  restart = "on-failure",
  condition = function() return blockos.device.kind() == "turtle" end,
  run = run,
}
