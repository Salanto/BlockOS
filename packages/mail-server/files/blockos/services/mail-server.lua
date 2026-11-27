-- mail-server service: keeps the domain's mailboxes on attached disk drives and serves
-- the mail protocol (see mail_protocol, mail_server). It needs at least one floppy
-- disk in a disk drive; a full disk spills over to the next one.

local function run(ctx)
  local rpc = import("rpc")
  local mail_protocol = import("mail_protocol")
  local mail_server = import("mail_server")
  local store = import("diskstore").open(mail_server.FOLDER)

  if not store.has_place() then
    ctx.log.warn("no disk: put a floppy disk into an attached disk drive")
    if blockos.notices then
      blockos.notices.mail_server = "The mail server needs a floppy disk in a disk drive"
    end
  end
  local found, domain = pcall(import, "domain")
  if not (found and domain.is_joined()) then
    error("the mail server needs a domain (its logins and groups)", 0)
  end
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
