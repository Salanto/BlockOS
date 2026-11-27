--- The mail server: mailboxes kept on disk drives, and the mail protocol's handlers
-- (see mail_protocol).
--
-- Every mailbox is one entry in a disk store (diskstore): it lives on a floppy in an
-- attached disk drive, never on the computer itself, and moves to the next disk when
-- its disk is full. Each user has an inbox ("<name>") and a sent folder
-- ("<name>@sent"). Who a message reaches and where they are logged in comes from the
-- directory (domain.route), so groups work and new mail is announced at once.
-- @module mail_server

local rpc = import("rpc")
local mail_protocol = import("mail_protocol")

local mail_server = {}

--- Messages kept per user (the oldest go first).
mail_server.MAX_MAIL = 20
mail_server.FOLDER = "blockos-mail"

--- Where messages go, how events leave, and time (tests replace these).
mail_server.env = {
  route = function(to) return import("domain").route(to) end,
  send = function(id, message, protocol) rednet.send(id, message, protocol) end,
  now = function() return math.floor(os.epoch("utc") / 1000) end,
}

local function unread_in(box)
  local count = 0
  for _, message in ipairs(box) do
    if not message.is_read then
      count = count + 1
    end
  end
  return count
end

--- Build the handler table.
-- @tparam table store From diskstore.open (read, write).
-- @treturn table handlers
function mail_server.handlers(store)
  local handlers = {}
  local with_args = rpc.with_args
  local last_id = 0

  -- Ids grow with the clock, so they stay unique across restarts.
  local function new_id()
    last_id = math.max(last_id + 1, os.epoch("utc"))
    return last_id
  end

  local function box_key(name, folder)
    if folder == "sent" then
      return name .. "@sent"
    end
    return name
  end

  local function own_box(fn)
    return function(ctx, args)
      local user, err = rpc.require_user(ctx)
      if not user then
        return nil, err
      end
      args = args or {}
      if args.folder and not mail_protocol.FOLDERS[args.folder] then
        return nil, "folders are inbox and sent"
      end
      local key = box_key(user.name, args.folder)
      return fn(key, store.read(key) or {}, args)
    end
  end

  local function append(key, box, message)
    box[#box + 1] = message
    while #box > mail_server.MAX_MAIL do
      table.remove(box, 1)
    end
    return store.write(key, box)
  end

  -- From a user, or from a joined computer (system notices, signed by its hostname).
  local function sender_of(ctx)
    if ctx.token then
      local user, err = rpc.require_user(ctx)
      return user and user.name, err
    end
    local computer, err = rpc.require_computer(ctx)
    return computer and computer.hostname, err
  end

  handlers.send = with_args(mail_protocol.ARGS.send, function(ctx, args)
    local from, err = sender_of(ctx)
    if not from then
      return nil, err
    end
    local is_user = ctx.token ~= nil
    if args.text == "" then
      return nil, "the message is empty"
    end
    local route, route_error = mail_server.env.route(args.to)
    if not route then
      return nil, route_error
    end
    local message = { id = new_id(), from = from, to = args.to, subject = args.subject,
      text = args.text, time = mail_server.env.now() }
    local delivered = 0
    for _, recipient in ipairs(route) do
      local box = store.read(recipient.name) or {}
      local stored, store_error = append(recipient.name, box, message)
      if not stored then
        return nil, store_error
      end
      delivered = delivered + 1
      -- "You've got mail": straight to wherever the recipient is logged in.
      local event = mail_protocol.new_mail_event({ to = recipient.name, from = from,
        unread = unread_in(box) })
      for _, id in ipairs(event and recipient.computers or {}) do
        mail_server.env.send(id, event, mail_protocol.NOTIFY_PROTOCOL)
      end
    end
    if is_user then
      local copy = {}
      for key, value in pairs(message) do
        copy[key] = value
      end
      copy.is_read = true
      append(box_key(from, "sent"), store.read(box_key(from, "sent")) or {}, copy)
    end
    return { sent = delivered }
  end)
  rpc.once(handlers.send) -- a repeat must not deliver the mail twice

  handlers.list = with_args(mail_protocol.ARGS.list, own_box(function(_, box)
    local list = {}
    for index = #box, 1, -1 do
      list[#list + 1] = box[index]
    end
    return list
  end))

  handlers.unread = own_box(function(_, box)
    return { unread = unread_in(box) }
  end)

  local function change(is_delete)
    return with_args(mail_protocol.ARGS.id, own_box(function(name, box, args)
      for index, message in ipairs(box) do
        if message.id == args.id then
          if is_delete then
            table.remove(box, index)
          else
            message.is_read = true
          end
          local stored, err = store.write(name, box)
          if not stored then
            return nil, err
          end
          return true
        end
      end
      return nil, "no such message"
    end))
  end

  handlers.read = change(false)
  handlers.delete = change(true)
  return handlers
end

return mail_server
