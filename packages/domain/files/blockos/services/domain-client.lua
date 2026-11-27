-- domain-client service: plugs the domain into the login screen and name
-- lookups, brings a domain user's roaming profile into their session, and reports
-- this computer's status to the controller.
--
-- The report is one direct message to the controller at boot, after a rename,
-- and every few minutes; no broadcasts.


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

  local function unread_notice(unread)
    if (unread or 0) == 0 then
      return nil
    end
    return unread .. " new message" .. (unread == 1 and "" or "s") .. ": type 'mail'"
  end

  -- Unread mail of the logged-in domain user, as a notice (at login and with every
  -- status report).
  local function mail_notice(user)
    if not (user and user.source == "domain" and user.token) then
      return nil
    end
    local result = domain.call_as(user.token, "mail_unread")
    return unread_notice(result and result.unread)
  end

  local function check_mail()
    local user = blockos.user
    local notice = mail_notice(user)
    -- The answer took a moment: only show it if the same user is still logged in.
    if blockos.notices and blockos.user == user then
      blockos.notices.mail = notice
    end
  end

  -- Roaming profiles: a domain user's apps and roaming settings, on any computer.
  -- One quick call at login: the profile carries the unread mail too. The mail notice
  -- is set for every login, so it never shows the previous user's.
  import("session").set_login_hook("domain-profile", function(user)
    if blockos.notices then
      blockos.notices.mail = nil
    end
    if user.source ~= "domain" or not user.token then
      return nil
    end
    local profile = domain.profile_get(user.token)
    if profile and blockos.notices then
      blockos.notices.mail = unread_notice(profile.unread)
    end
    return profile
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
      " not set up for the domain yet: a domain admin can run 'domain setup' (domain-tools)"
  end

  -- New mail while someone is logged in: the controller tells this computer at once.
  -- The notice updates, scripts can react to the "blockos_mail" event, and the user's
  -- mail sound plays (a roaming setting: everyone picks their own).
  local wire = import("wire")
  local function on_mail(sender, message)
    local membership = domain.membership()
    local event = wire.parse(message, "event", domain.MAIL_SCHEMA)
    local user = blockos.user
    if not (event and event.topic == domain.MAIL_TOPIC and membership
      and sender == membership.controller_id) then
      return
    end
    if not (user and user.source == "domain" and user.name == event.data.to) then
      return
    end
    if blockos.notices then
      blockos.notices.mail = unread_notice(event.data.unread)
    end
    os.queueEvent(domain.MAIL_EVENT, event.data.from, event.data.unread)
    local sound = domain.mail_sound(ctx.config.get("blockos.mail.sound"))
    if sound then
      import("sound").play(sound, { 18, 14 }) -- "ding dong"
    end
  end

  local interval = ctx.config.get("blockos.domain.heartbeat_interval", 300)
  local timer = os.startTimer(interval)
  while true do
    local event, id, message, protocol = import("events").pull()
    if event == "rednet_message" and protocol == domain.MAIL_PROTOCOL then
      on_mail(id, message)
    elseif event == "timer" and id == timer then
      report()
      check_mail()
      timer = os.startTimer(interval)
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
