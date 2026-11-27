--- The mail client's settings and helpers: the new-mail sound and the notice text.
-- @module mail_client

local config = import("config")

local mail_client = {}

config.define("blockos.mail.sound", {
  description = "Sound for new mail: note:<instrument>, sound:<event>, file:<.dfpwm> or off.",
  default = "note:chime",
  type = "string",
  roams = true, -- your own sound, on every computer you log into
})

--- The new-mail sound from its setting text ("note:chime", "file:/mail.dfpwm", "off").
-- @tparam string text
-- @treturn table|nil a sound for the core sound module, nil for off
function mail_client.sound(text)
  local kind, value = tostring(text):match("^(%a+):(.+)$")
  if kind == "note" or kind == "sound" or kind == "file" then
    return { kind = kind, value = value, volume = 1 }
  end
  return nil
end

--- The notice for unread mail, or nil when there is none.
-- @tparam number unread
function mail_client.notice(unread)
  if (unread or 0) == 0 then
    return nil
  end
  return unread .. " new message" .. (unread == 1 and "" or "s") .. ": type 'mail'"
end

return mail_client
