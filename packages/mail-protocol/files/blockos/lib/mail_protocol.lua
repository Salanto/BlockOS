--- Mail between the players of a domain: the protocol and the client library.
--
-- A mail server (package mail-server) keeps the mailboxes; it is found through the
-- domain service record "mail". Users are checked with the directory's logins.
--
-- rpc, protocol PROTOCOL ("blockos.mail"):
--   send { to (user or group), subject?, text }
--                                        a logged-in user, or a joined computer (notices)
--   list { folder? }                     the caller's messages, newest first; folder is
--                                        "inbox" (default) or "sent"
--   unread                               { unread = n } in the inbox
--   read { id, folder? }, delete { id, folder? }
--                                        the caller's own messages
-- A message is { id, from, to, subject?, text, time, is_read? }.
-- event, protocol NOTIFY_PROTOCOL: NEW_MAIL_TOPIC { to, from, unread }, sent by the
-- server to each computer the recipient is logged in at; there it becomes the local
-- event NEW_MAIL_EVENT (from, unread) for scripts.
-- @module mail_protocol

local rpc = import("rpc")
local wire = import("wire")

local mail_protocol = {}

mail_protocol.PROTOCOL = "blockos.mail"
mail_protocol.NOTIFY_PROTOCOL = "blockos.mail.notify"
mail_protocol.SERVICE_TYPE = "mail"
mail_protocol.NEW_MAIL_TOPIC = "new_mail"
mail_protocol.NEW_MAIL_EVENT = "blockos_mail"
mail_protocol.MAX_LENGTH = 300
mail_protocol.MAX_SUBJECT = 40
mail_protocol.FOLDERS = { inbox = true, sent = true }

local NAME = { type = "string", max = 32 }

--- Argument schemas (see wire.validate).
local FOLDER = { type = "string", max = 8, optional = true }
mail_protocol.ARGS = {
  send = {
    to = NAME,
    subject = { type = "string", max = mail_protocol.MAX_SUBJECT, optional = true },
    text = { type = "string", max = mail_protocol.MAX_LENGTH },
  },
  list = { folder = FOLDER },
  id = { id = "number", folder = FOLDER },
}

mail_protocol.NEW_MAIL_SCHEMA = {
  to = NAME,
  from = NAME,
  unread = { type = "number", min = 0 },
}

--- Build a new-mail event, checked against NEW_MAIL_SCHEMA before it goes out.
-- @tparam table data { to, from, unread }
-- @treturn[1] table A wire event.
-- @treturn[2] nil
-- @treturn[2] string error message
function mail_protocol.new_mail_event(data)
  local ok, err = wire.validate(data, mail_protocol.NEW_MAIL_SCHEMA)
  if not ok then
    return nil, err
  end
  return wire.event(mail_protocol.NEW_MAIL_TOPIC, data)
end

--- The mail server, if there is one.
-- @treturn[1] number Computer ID.
-- @treturn[2] nil
-- @treturn[2] string error message
function mail_protocol.find_server()
  local id = import("discovery").find(mail_protocol.SERVICE_TYPE, mail_protocol.PROTOCOL)
  if not id then
    return nil, "no mail server found (install mail-server on a computer with disk drives)"
  end
  return id
end

--- Call the mail server.
-- @tparam string op
-- @param[opt] args
-- @tparam[opt] table options rpc options (token, timeout, retries, relogin)
-- @return The result, or nil and an error message.
function mail_protocol.call(op, args, options)
  local id, err = mail_protocol.find_server()
  if not id then
    return nil, err
  end
  local result, call_error = rpc.call(id, mail_protocol.PROTOCOL, op, args, options)
  if not result and tostring(call_error):find("no answer") then
    import("discovery").forget(mail_protocol.SERVICE_TYPE)
  end
  return result, call_error
end

return mail_protocol
