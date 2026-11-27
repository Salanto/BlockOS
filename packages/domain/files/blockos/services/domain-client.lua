-- domain-client service: plugs the domain into the login screen and name
-- lookups, brings a domain user's roaming profile into their session, and reports
-- this computer's status to the controller.
--
-- The report is one direct message to the controller at boot, after a rename,
-- and every few minutes; no broadcasts. It carries this computer's problems (notices
-- with a level: a failed service, a missing disk), which the controller raises as
-- alerts, so it also goes out a moment after they change.

-- Problems often change in bursts (a service crashing and giving up): wait this long
-- and send them all in one report.
local PROBLEMS_DELAY_SECONDS = 2


local function run(ctx)
  local auth = import("auth")
  local domain = import("domain")
  local rpc = import("rpc")

  auth.register_provider("domain", domain.login_provider())
  rpc.set_user_validator(domain.validate)
  rpc.set_computer_validator(domain.validate_computer)

  if not domain.is_joined() then
    ctx.log.info("not in a domain")
    return
  end
  ctx.log.info("member of domain %s", domain.name())

  -- Roaming profile at login: one quick call (see domain.QUICK_SECONDS).
  import("session").set_login_hook("domain-profile", function(user)
    if user.source ~= "domain" or not user.token then
      return nil
    end
    return domain.profile_get(user.token)
  end)

  local function report()
    local net = blockos.net
    if not net or not net.hostname() then
      return
    end
    local announce = net.build_announce().data
    local ok, err = domain.report({
      hostname = net.hostname(),
      info = announce.info,
      kind = announce.kind,
      version = announce.version,
      problems = import("notices").problems(),
    })
    if not ok then
      ctx.log.warn("status report failed: %s", tostring(err))
    end
  end

  -- Wait for the net service to come up, then use the controller for lookups.
  while not blockos.net do
    sleep(1)
  end
  blockos.net.set_directory(domain.net_directory())
  report()

  -- Packages with roles that no domain admin set up yet: still open, but say so.
  local pending = import("roles").pending()
  if #pending > 0 then
    import("notices").set("roles", table.concat(pending, ", ") ..
      " not set up for the domain yet: a domain admin can run 'domain setup' (domain-tools)")
  end

  local interval = ctx.config.get("blockos.domain.heartbeat_interval", 300)
  local timer = os.startTimer(interval)
  local problems_timer = nil
  while true do
    local event, id = import("events").pull()
    if event == "timer" and id == timer then
      report()
      timer = os.startTimer(interval)
    elseif event == import("notices").PROBLEMS_EVENT and not problems_timer then
      problems_timer = os.startTimer(PROBLEMS_DELAY_SECONDS)
    elseif event == "timer" and id == problems_timer then
      problems_timer = nil
      report()
    elseif event == import("net").RENAME_EVENT then
      sleep(3) -- let the net service register the new name first
      report()
    end
  end
end

return {
  name = "domain-client",
  description = "Domain logins, name lookups and status reports",
  after = { "net" },
  restart = "on-failure",
  run = run,
}
