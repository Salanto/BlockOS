--- Chat messages between computers (protocol "blockos.msg").
-- @module messages

local wire = import("wire")

local messages = {}

messages.PROTOCOL = "blockos.msg"
messages.TOPIC = "message"
messages.MAX_LENGTH = 200

--- Payload of a message event.
messages.SCHEMA = {
  from = { type = "string", max = 64 },
  text = { type = "string", max = messages.MAX_LENGTH },
}

--- Who this computer says a message is from: "user@host".
-- @treturn string
function messages.sender_name()
  local user = blockos and blockos.user and blockos.user.name or "someone"
  local host = blockos and blockos.net and blockos.net.full_hostname()
    or ("#" .. os.getComputerID())
  return user .. "@" .. host
end

--- Build a message event.
-- @tparam string text
-- @treturn table
function messages.event(text)
  return wire.event(messages.TOPIC, {
    from = messages.sender_name(),
    text = text:sub(1, messages.MAX_LENGTH),
  })
end

return messages
