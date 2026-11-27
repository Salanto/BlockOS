--- The mail app: folders, a message list and a reading pane, a bit like Outlook.
--
-- Wide screens show folders on the left, the list at the top right and the selected
-- message below it. Narrow screens (turtles, pocket computers) show the list, and the
-- message on its own screen after Enter. Advanced computers get colours and mouse
-- clicks; everything works with the keyboard alone:
--   up/down choose   Tab folder   Enter open   n new   r reply   d delete   q quit
-- New mail shows up at once (the blockos_mail event).
-- @module mail_app

local mail_protocol = import("mail_protocol")
local ui = import("ui")

local mail_app = {}

mail_app.FOLDERS = { "inbox", "sent" }
mail_app.FOLDER_TITLES = { inbox = "Inbox", sent = "Sent" }
--- Below this width the app shows one thing at a time.
mail_app.WIDE = 45
local FOLDER_WIDTH = 11
local REFRESH_SECONDS = 30

------------------------------------------------------------------------------
-- Layout and text (pure: tested without a screen)
------------------------------------------------------------------------------

--- Where everything goes.
-- @tparam number width
-- @tparam number height
-- @treturn table { is_wide, folders = {x,y,w,h}?, list = {x,y,w,h}, preview = {x,y,w,h}? }
function mail_app.layout(width, height)
  local top, bottom = 2, height - 2 -- header above, status line and hints below
  if width < mail_app.WIDE then
    return { is_wide = false, tabs_y = top, list = { x = 1, y = top + 1, w = width,
      h = bottom - top } }
  end
  local right_x = FOLDER_WIDTH + 2
  local right_w = width - right_x + 1
  local list_h = math.max(3, math.floor((bottom - top + 1) * 0.4))
  return {
    is_wide = true,
    folders = { x = 1, y = top, w = FOLDER_WIDTH, h = bottom - top + 1 },
    list = { x = right_x, y = top, w = right_w, h = list_h },
    preview = { x = right_x, y = top + list_h + 1, w = right_w, h = bottom - top - list_h },
  }
end

--- How long ago: "5m", "3h", "2d".
function mail_app.age(time, now)
  if not time then
    return "?"
  end
  local seconds = math.max(0, (now or math.floor(os.epoch("utc") / 1000)) - time)
  if seconds < 3600 then
    return math.floor(seconds / 60) .. "m"
  elseif seconds < 86400 then
    return math.floor(seconds / 3600) .. "h"
  end
  return math.floor(seconds / 86400) .. "d"
end

--- A message's subject, or the start of its text.
function mail_app.subject(message)
  if message.subject and message.subject ~= "" then
    return message.subject
  end
  return (tostring(message.text):gsub("%s+", " "))
end

--- One line of the message list.
-- @tparam table message
-- @tparam string folder "inbox" shows the sender, "sent" the recipient
-- @tparam number width
-- @tparam[opt] number now
function mail_app.list_line(message, folder, width, now)
  local who = folder == "sent" and ("to " .. tostring(message.to)) or tostring(message.from)
  local mark = message.is_read and " " or "*"
  local age = mail_app.age(message.time, now)
  local who_w = math.min(12, math.max(4, math.floor(width / 4)))
  local subject_w = math.max(1, width - who_w - #age - 3)
  return mark .. ui.pad(ui.fit(who, who_w), who_w) .. " " ..
    ui.pad(ui.fit(mail_app.subject(message), subject_w), subject_w) .. " " .. age
end

--- A reply's subject: "Re: ..." once.
function mail_app.reply_subject(message)
  local subject = message.subject or ""
  if subject:lower():sub(1, 4) == "re: " then
    return subject
  end
  return ("Re: " .. (subject ~= "" and subject or mail_app.subject(message))):sub(1, 40)
end

------------------------------------------------------------------------------
-- The app
------------------------------------------------------------------------------

--- Run the app until q.
-- @tparam function call function(op, args) -> result | nil, err (the mail server)
-- @tparam string user_name Shown in the header.
function mail_app.run(call, user_name)
  local view = { folder = 1, messages = {}, selected = 1, scroll = 0, is_reading = false,
    message = nil, role = "dim" }
  local counts = {}

  local function folder_name()
    return mail_app.FOLDERS[view.folder]
  end

  local function current()
    return view.messages[view.selected]
  end

  local function set_message(text, role)
    view.status, view.role = text, role or "dim"
  end

  local function load()
    local messages, err = call("list", { folder = folder_name() })
    if not messages then
      set_message(err, "error")
      messages = {}
    end
    view.messages = messages
    view.selected = math.max(1, math.min(view.selected, #messages))
    local unread = call("unread")
    counts.inbox = unread and unread.unread or counts.inbox
  end

  -- Reading a message marks it read (on the server too).
  local function mark_read(message)
    if message and not message.is_read and folder_name() == "inbox" then
      message.is_read = true
      call("read", { id = message.id, folder = "inbox" })
      counts.inbox = math.max(0, (counts.inbox or 1) - 1)
    end
  end

  local function draw_folders(box)
    for index, name in ipairs(mail_app.FOLDERS) do
      local title = mail_app.FOLDER_TITLES[name]
      if name == "inbox" and (counts.inbox or 0) > 0 then
        title = title .. " " .. counts.inbox
      end
      local is_current = index == view.folder
      local role, background = "text", nil
      if is_current then
        role, background = "selected_text", "selected"
      end
      ui.text_at(box.x, box.y + index - 1, ui.pad(" " .. title, box.w), role, background)
    end
    for y = box.y, box.y + box.h - 1 do
      ui.text_at(box.x + box.w, y, "|", "faint")
    end
  end

  local function draw_list(box)
    if #view.messages == 0 then
      ui.text_at(box.x + 1, box.y, "(no messages)", "faint")
      return
    end
    if view.selected <= view.scroll then
      view.scroll = view.selected - 1
    elseif view.selected > view.scroll + box.h then
      view.scroll = view.selected - box.h
    end
    for row = 1, box.h do
      local index = view.scroll + row
      local message = view.messages[index]
      if not message then
        break
      end
      local line = mail_app.list_line(message, folder_name(), box.w)
      if index == view.selected then
        ui.text_at(box.x, box.y + row - 1, line, "selected_text", "selected")
      else
        ui.text_at(box.x, box.y + row - 1, line, message.is_read and "dim" or "text")
      end
    end
  end

  local function draw_message(box, message)
    if not message then
      return
    end
    local y = box.y
    local function field(label, value)
      ui.text_at(box.x, y, label, "dim")
      ui.text_at(box.x + #label, y, ui.fit(tostring(value), box.w - #label), "text")
      y = y + 1
    end
    field("From: ", message.from)
    field("To:   ", message.to)
    field("Subj: ", mail_app.subject(message))
    ui.text_at(box.x, y, ui.fit(string.rep("-", box.w), box.w), "faint")
    y = y + 1
    for _, line in ipairs(ui.wrap(message.text, box.w)) do
      if y > box.y + box.h - 1 then
        break
      end
      ui.text_at(box.x, y, line, "text")
      y = y + 1
    end
  end

  local function draw()
    local width, height = ui.size()
    local layout = mail_app.layout(width, height)
    ui.clear()
    local unread = (counts.inbox or 0) > 0 and (counts.inbox .. " new") or ""
    ui.header(1, "Mail " .. ui.GLYPHS.dot .. " " .. tostring(user_name), unread)
    if layout.is_wide then
      draw_folders(layout.folders)
      draw_list(layout.list)
      ui.text_at(layout.preview.x, layout.preview.y - 1,
        string.rep(ui.GLYPHS.rule, layout.preview.w), "faint")
      draw_message(layout.preview, current())
    elseif view.is_reading then
      draw_message({ x = 1, y = 2, w = width, h = height - 3 }, current())
    else
      local titles = {}
      for index, name in ipairs(mail_app.FOLDERS) do
        titles[index] = mail_app.FOLDER_TITLES[name]
      end
      ui.tabs(layout.tabs_y, titles, view.folder)
      draw_list(layout.list)
    end
    if view.status then
      ui.line(height - 1, view.status, view.role)
    end
    local hints = { { "n", "New" }, { "r", "Reply" }, { "d", "Delete" }, { "Tab", "Folder" },
      { "q", view.is_reading and "Back" or "Quit" } }
    ui.footer(hints)
    return layout
  end

  local function compose(to, subject)
    local answers = ui.form(to and ("Reply to " .. to) or "New message", {
      { label = "To: ", default = to },
      { label = "Subject: ", default = subject },
      { label = "Text: " },
    })
    if not answers then
      return set_message("Not sent.", "dim")
    end
    if answers[3] == "" then
      return set_message("Not sent: the message is empty.", "warn")
    end
    local result, err = call("send", { to = answers[1], subject = answers[2], text = answers[3] })
    if not result then
      return set_message(err, "error")
    end
    set_message("Sent to " .. result.sent .. " user" .. (result.sent == 1 and "" or "s") .. ".",
      "ok")
  end

  local function delete()
    local message = current()
    if message and ui.confirm("Delete \"" .. ui.fit(mail_app.subject(message), 20) .. "\"?") then
      local ok, err = call("delete", { id = message.id, folder = folder_name() })
      set_message(ok and "Deleted." or err, ok and "ok" or "error")
      view.is_reading = false
    end
  end

  local function switch_folder(index)
    view.folder = (index - 1) % #mail_app.FOLDERS + 1
    view.selected, view.scroll, view.is_reading = 1, 0, false
    load()
  end

  local function move(step)
    view.selected = math.max(1, math.min(#view.messages, view.selected + step))
  end

  local function click(layout, x, y)
    if layout.is_wide and x <= layout.folders.w and y - layout.folders.y + 1 <= #mail_app.FOLDERS
      and y >= layout.folders.y then
      return switch_folder(y - layout.folders.y + 1)
    end
    local list = layout.list
    if x >= list.x and y >= list.y and y < list.y + list.h then
      local index = view.scroll + y - list.y + 1
      if view.messages[index] then
        view.selected = index
        view.is_reading = not layout.is_wide
      end
    end
  end

  load()
  local events = import("events")
  local refresh = os.startTimer(REFRESH_SECONDS)
  while true do
    local layout = draw()
    if layout.is_wide or view.is_reading then
      mark_read(current())
    end
    local event, a, b, c = events.pull()
    if event == "key" then
      if a == keys.up then
        move(-1)
      elseif a == keys.down then
        move(1)
      elseif a == keys.pageUp then
        move(-5)
      elseif a == keys.pageDown then
        move(5)
      elseif a == keys.tab then
        switch_folder(view.folder + 1)
      elseif a == keys.enter and not layout.is_wide then
        view.is_reading = current() ~= nil
      elseif a == keys.backspace then
        view.is_reading = false
      end
    elseif event == "char" then
      if a == "q" then
        if view.is_reading then
          view.is_reading = false
        else
          break
        end
      elseif a == "n" then
        compose()
        load()
      elseif a == "r" and current() then
        compose(current().from, mail_app.reply_subject(current()))
        load()
      elseif a == "d" then
        delete()
        load()
      end
    elseif event == "mouse_click" then
      click(layout, b, c)
    elseif event == "mouse_scroll" then
      move(a)
    elseif event == mail_protocol.NEW_MAIL_EVENT then
      set_message("New mail from " .. tostring(a) .. ".", "ok")
      load()
    elseif event == "timer" and a == refresh then
      load()
      refresh = os.startTimer(REFRESH_SECONDS)
    elseif event == "term_resize" then
      view.scroll = 0
    end
  end
  ui.clear()
end

return mail_app
