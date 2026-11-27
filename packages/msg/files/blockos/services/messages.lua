-- messages service: receives `msg` chat messages from other computers.
--
-- Messages are kept in memory (the newest 20). While some are unread, the
-- welcome screen shows a notice and a speaker (if attached) chimes once per
-- message. `msg` with no arguments shows and clears them.

local MAX_MESSAGES = 20

local function chime()
  for _, name in ipairs(peripheral.getNames()) do
    if peripheral.hasType(name, "speaker") then
      peripheral.wrap(name).playNote("chime", 1, 18)
      return
    end
  end
end

local function run()
  local messages = import("messages")
  local wire = import("wire")
  blockos.messages = blockos.messages or { inbox = {}, unread = 0 }
  local box = blockos.messages

  while true do
    local _, sender, message, protocol = os.pullEvent("rednet_message")
    if protocol == messages.PROTOCOL then
      local event = wire.parse(message, "event", messages.SCHEMA)
      if event and event.topic == messages.TOPIC then
        box.inbox[#box.inbox + 1] = {
          from = event.data.from,
          text = event.data.text,
          sender = sender,
          time = textutils.formatTime(os.time(), true),
        }
        if #box.inbox > MAX_MESSAGES then
          table.remove(box.inbox, 1)
        end
        box.unread = box.unread + 1
        blockos.notices.msg = box.unread .. " new message(s): type 'msg'"
        chime()
        os.queueEvent(import("session").NOTICE_EVENT, "msg", event.data)
      end
    end
  end
end

return {
  name = "messages",
  description = "Receives chat messages from other computers",
  after = { "net" },
  restart = "on-failure",
  run = run,
}
