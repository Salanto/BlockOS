-- mail-server service: keeps the domain's mailboxes on attached disk drives and serves
-- the mail protocol (see mail_protocol, mail_server). It needs at least one floppy
-- disk in a disk drive; a full disk spills over to the next one.

-- How often to look again for a domain (a disk being put in is an event).
local RECHECK_SECONDS = 30

-- Wait until the computer is in a domain and a floppy is in a drive, with a notice
-- saying what is missing (installs by computer roles can't ask anyone).
local function wait_until_ready(ctx, store)
  local requirements = import("requirements")
  local notices = import("notices")
  local said = nil
  while true do
    local missing = nil
    if not requirements.is_met("domain") then
      missing = "The mail server needs a domain: join one or run dcpromo"
    elseif not store.has_place() then
      missing = "The mail server needs a floppy disk in a disk drive"
    end
    if not missing then
      notices.clear("mail_server")
      return
    end
    if missing ~= said then
      ctx.log.warn("%s", missing)
      notices.set("mail_server", missing)
      said = missing
    end
    local timer = os.startTimer(RECHECK_SECONDS)
    repeat
      local event, value = os.pullEvent()
    until event == "disk" or event == "peripheral" or (event == "timer" and value == timer)
  end
end

local function run(ctx)
  local rpc = import("rpc")
  local mail_protocol = import("mail_protocol")
  local mail_server = import("mail_server")
  local store = import("diskstore").open(mail_server.FOLDER)

  wait_until_ready(ctx, store)
  local ok, err = import("discovery").advertise(mail_protocol.SERVICE_TYPE, mail_protocol.PROTOCOL)
  if not ok then
    ctx.log.warn("could not register the mail service record: %s", tostring(err))
  end
  local free, places = store.free()
  ctx.log.info("mailboxes on %d disk(s), %d bytes free", places, free)
  rpc.serve(mail_protocol.PROTOCOL, mail_server.handlers(store))
end

return {
  name = "mail-server",
  description = "Keeps the domain's mailboxes on disk drives",
  after = { "net", "domain-client" },
  restart = "on-failure",
  run = run,
}
