-- manage service: remote admin for domain admins (protocol "blockos.manage"): health,
-- reboot, update now, services, the log, and remote shells (remote_shell.lua). Runs on
-- every computer joined to a domain.

local function run(ctx)
  local domain = import("domain")
  if not domain.is_joined() then
    ctx.log.info("not in a domain: remote admin is off")
    return
  end
  local manage = import("manage")
  local remote_shell = import("remote_shell")
  local rpc = import("rpc")
  local shells = remote_shell.server()

  parallel.waitForAny(
    function() rpc.serve(manage.PROTOCOL, manage.handlers(shells)) end,
    function()
      -- A timer keeps the session timeouts ticking even when nothing else happens.
      local tick = os.startTimer(remote_shell.PING_SECONDS)
      while true do
        local event = table.pack(os.pullEventRaw())
        if event[1] == manage.REBOOT_EVENT then
          ctx.log.info("reboot requested by a domain admin")
          sleep(1) -- let the reply leave first
          os.reboot()
        elseif event[1] == "timer" and event[2] == tick then
          tick = os.startTimer(remote_shell.PING_SECONDS)
        end
        shells.handle(table.unpack(event, 1, event.n))
      end
    end
  )
end

return {
  name = "manage",
  description = "Remote admin for domain admins (health, reboot, update, remote shell)",
  after = { "net", "domain-client" },
  restart = "on-failure",
  run = run,
}
