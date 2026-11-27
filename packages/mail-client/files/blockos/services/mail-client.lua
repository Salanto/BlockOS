-- mail-client service: tells a logged-in domain user about their mail.
--
-- At login (a quick check, see domain.QUICK_SECONDS) and every few minutes it asks the
-- mail server how many messages are unread and shows a notice. New mail arrives at
-- once: the server sends new_mail to the computer the user is logged in at; then the
-- notice updates, the local event "blockos_mail" (from, unread) is queued for scripts,
-- and the user's mail sound plays (blockos.mail.sound, a roaming setting).

local CHECK_SECONDS = 300

local function run()
  local events = import("events")
  local mail_client = import("mail_client")
  local mail_protocol = import("mail_protocol")
  local wire = import("wire")

  local function is_domain_user(user)
    return user and user.source == "domain" and user.token
  end

  local function quick_unread(user)
    local quick = import("domain").QUICK_SECONDS / 2
    local result = mail_protocol.call("unread", nil,
      { token = user.token, timeout = quick, retries = 1 })
    return result and result.unread
  end

  local function show(notice)
    import("notices").set("mail", notice)
  end

  -- Set for every login, so a notice never shows the previous user's mail.
  import("session").set_login_hook("mail", function(user)
    show(nil)
    if is_domain_user(user) then
      show(mail_client.notice(quick_unread(user)))
    end
    return nil
  end)

  local function check()
    local user = blockos.user
    if not is_domain_user(user) then
      return
    end
    local notice = mail_client.notice(quick_unread(user))
    if blockos.user == user then -- the answer took a moment: still the same user?
      show(notice)
    end
  end

  local function on_new_mail(sender, message)
    local event = wire.parse(message, "event", mail_protocol.NEW_MAIL_SCHEMA)
    local user = blockos.user
    if not (event and event.topic == mail_protocol.NEW_MAIL_TOPIC) then
      return
    end
    if sender ~= mail_protocol.find_server() then
      return -- only the mail server announces mail
    end
    if not (is_domain_user(user) and user.name == event.data.to) then
      return
    end
    show(mail_client.notice(event.data.unread))
    os.queueEvent(mail_protocol.NEW_MAIL_EVENT, event.data.from, event.data.unread)
    -- The user's own sound (a roaming setting), not this computer's.
    local sound = mail_client.sound(import("config").get("blockos.mail.sound"))
    if sound then
      import("sound").play(sound, { 18, 14 }) -- "ding dong"
    end
  end

  local timer = os.startTimer(CHECK_SECONDS)
  while true do
    local event, a, b, c = events.pull()
    if event == "rednet_message" and c == mail_protocol.NOTIFY_PROTOCOL then
      on_new_mail(a, b)
    elseif event == "timer" and a == timer then
      check()
      timer = os.startTimer(CHECK_SECONDS)
    end
  end
end

return {
  name = "mail-client",
  description = "Mail notices, the new-mail sound and the blockos_mail event",
  after = { "net", "domain-client" },
  restart = "on-failure",
  run = run,
}
