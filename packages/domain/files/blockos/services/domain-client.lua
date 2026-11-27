-- domain-client service: plugs the domain into the login screen and name
-- lookups, brings a domain user's roaming profile into their session, and reports
-- this computer's status to the controller.
--
-- The report is one direct message to the controller at boot, after a rename,
-- and every few minutes; no broadcasts.

local HEARTBEAT_EVENT = "blockos_net_rename"

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

  -- Unread mail of the logged-in domain user, as a notice (at login and with every
  -- status report).
  local function mail_notice(user)
    if not (user and user.source == "domain" and user.token) then
      return nil
    end
    local result = domain.call_as(user.token, "mail_unread")
    local unread = result and result.unread or 0
    if unread == 0 then
      return nil
    end
    return unread .. " new message" .. (unread == 1 and "" or "s") .. ": type 'mail'"
  end

  local function check_mail()
    if blockos.notices then
      blockos.notices.mail = mail_notice(blockos.user)
    end
  end

  -- Roaming profiles: a domain user's apps and roaming settings, on any computer.
  -- The mail notice is set for every login, so it never shows the previous user's.
  import("session").set_login_hook("domain-profile", function(user)
    if blockos.notices then
      blockos.notices.mail = mail_notice(user)
    end
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
  if #pending > 0 and blockos.notices then
    blockos.notices.roles = table.concat(pending, ", ") ..
      " not set up for the domain yet: a domain admin can run 'domain setup'"
  end

  local interval = ctx.config.get("blockos.domain.heartbeat_interval", 300)
  local timer = os.startTimer(interval)
  while true do
    local event, id = os.pullEvent()
    if event == "timer" and id == timer then
      report()
      check_mail()
      timer = os.startTimer(interval)
    elseif event == HEARTBEAT_EVENT then
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
