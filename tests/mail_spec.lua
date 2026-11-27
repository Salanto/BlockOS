-- Mail: the disk store (floppies, spilling to the next disk), the mail server's
-- handlers (users, groups, notices, the sent folder) and the mail app's layout.
return function(t)
  -- Two drives with floppies mounted at /sandbox-disk1 and /sandbox-disk2.
  local function fake_drives(import, free)
    local diskstore = import("diskstore")
    for _, path in ipairs({ "/sandbox-disk1", "/sandbox-disk2" }) do
      if fs.exists(path) then
        fs.delete(path)
      end
      fs.makeDir(path)
    end
    local mounts = { drive_0 = "sandbox-disk1", drive_1 = "sandbox-disk2" }
    diskstore.env.peripheral = t.fake_peripherals({
      drive_0 = { types = { "drive" }, methods = {} },
      drive_1 = { types = { "drive" }, methods = {} },
      monitor_0 = { types = { "monitor" }, methods = {} },
    })
    diskstore.env.disk = {
      hasData = function(name) return mounts[name] ~= nil end,
      getMountPath = function(name) return mounts[name] end,
    }
    diskstore.env.free = free
    return diskstore
  end

  local function cleanup()
    for _, path in ipairs({ "/sandbox-disk1", "/sandbox-disk2" }) do
      if fs.exists(path) then
        fs.delete(path)
      end
    end
  end

  t.it("a disk store never uses a BlockOS install or package disk", function()
    local import = t.fresh_import()
    local diskstore = fake_drives(import, function() return 100000 end)
    local file = fs.open("/sandbox-disk1/index.lua", "w")
    file.write("{}")
    file.close()
    local store = diskstore.open("blockos-mail")
    t.eq(#store.places(), 1, "only the plain floppy")
    t.eq(store.places()[1], "/sandbox-disk2/blockos-mail")
    t.ok(diskstore.has_disk())
    file = fs.open("/sandbox-disk2/index.lua", "w")
    file.write("{}")
    file.close()
    t.ok(not diskstore.has_disk(), "install disks alone do not count")
    cleanup()
  end)

  t.it("requirements: a missing disk waits, a missing domain only warns", function()
    local import = t.fresh_import()
    local requirements = import("requirements")
    local has_disk, is_joined = false, false
    requirements.env.has_disk = function() return has_disk end
    requirements.env.is_joined = function() return is_joined end
    local manifest = { name = "mail-server", requires = { "disk", "domain", "unknown" } }
    local missing = requirements.missing(manifest)
    t.eq(#missing, 2, "unknown names are ignored")
    t.eq(missing[1].name, "disk")
    t.ok(missing[1].wait and missing[1].message:find("^mail%-server "))
    t.eq(missing[2].name, "domain")
    t.ok(not missing[2].wait)
    has_disk, is_joined = true, true
    t.eq(#requirements.missing(manifest), 0)
    t.ok(requirements.is_met("disk") and requirements.is_met("unknown"))
    t.eq(#requirements.missing({ name = "plain" }), 0, "no requires, nothing missing")
  end)

  t.it("a disk store keeps entries on floppies and spills to the next disk", function()
    local import = t.fresh_import()
    local full = {}
    local diskstore = fake_drives(import, function(path)
      return path:find("^/?sandbox%-disk1") and full.disk1 and 0 or 100000
    end)
    local store = diskstore.open("blockos-mail")
    t.eq(#store.places(), 2, "both floppies, not the computer")
    t.eq(store.write("bob", { "hello" }), "/sandbox-disk1/blockos-mail")
    t.eq(store.read("bob")[1], "hello")
    full.disk1 = true
    t.eq(store.write("bob", { "hello", "more" }), "/sandbox-disk2/blockos-mail",
      "the first disk is full: the entry moves")
    t.ok(not fs.exists("/sandbox-disk1/blockos-mail/bob"), "and the old copy is gone")
    t.eq(#store.read("bob"), 2)
    full.disk1, full.disk2 = true, true
    diskstore.env.free = function() return 0 end
    local ok, err = store.write("carol", { "x" })
    t.ok(not ok and err:find("full"), tostring(err))
    cleanup()
  end)

  t.it("a store without disks says so; the package server may use the computer", function()
    local import = t.fresh_import()
    local diskstore = import("diskstore")
    diskstore.env.peripheral = t.fake_peripherals({})
    local mail = diskstore.open("blockos-mail")
    t.ok(not mail.has_place())
    local _, err = mail.write("bob", {})
    t.ok(err:find("floppy"), err)
    local repo = diskstore.open("blockos-repo", { computer = "first",
      computer_path = "/sandbox/repo" })
    t.eq(repo.places()[1], "/sandbox/repo", "the computer first, disks when it is full")
  end)

  local USERS = {
    ["bob-token"] = { name = "bob", groups = { "domain-users" } },
    ["carol-token"] = { name = "carol", groups = { "domain-users" } },
  }

  local function new_server()
    local import = t.fresh_import()
    local rpc = import("rpc")
    rpc.set_user_validator(function(token) return USERS[token] end)
    rpc.set_computer_validator(function(token)
      return token == "farm-token" and { hostname = "farm" } or nil
    end)
    local diskstore = fake_drives(import)
    local mail_server = import("mail_server")
    local sent = {}
    mail_server.env.route = function(to)
      if to == "miners" then
        return { { name = "bob", computers = { 7 } }, { name = "carol", computers = {} } }
      elseif USERS[to .. "-token"] then
        return { { name = to, computers = to == "bob" and { 7 } or {} } }
      end
      return nil, "no user or group called " .. to
    end
    mail_server.env.send = function(id, message, protocol)
      sent[#sent + 1] = { id = id, message = message, protocol = protocol }
    end
    return mail_server.handlers(diskstore.open("blockos-mail")), sent
  end

  local BOB = { sender = 7, token = "bob-token" }
  local CAROL = { sender = 8, token = "carol-token" }

  t.it("the mail server delivers to users and groups and announces new mail", function()
    local handlers, sent = new_server()
    t.eq(handlers.send(CAROL, { to = "bob", subject = "lunch", text = "pizza?" }).sent, 1)
    t.eq(#sent, 1, "bob is logged in at computer 7")
    t.eq(sent[1].id, 7)
    t.eq(sent[1].protocol, "blockos.mail.notify")
    t.eq(sent[1].message.data.unread, 1)
    t.eq(handlers.send(BOB, { to = "miners", text = "dig" }).sent, 2)
    t.eq(handlers.send({ sender = 9, computer_token = "farm-token" },
      { to = "bob", text = "iron low" }).sent, 1, "joined computers send notices")
    t.ok(not handlers.send({ sender = 9 }, { to = "bob", text = "x" }), "anonymous")
    t.ok(not handlers.send(BOB, { to = "nobody", text = "x" }))
    t.ok(not handlers.send(BOB, { to = "carol", text = "" }), "empty")

    local inbox = handlers.list(BOB, {})
    t.eq(#inbox, 3)
    t.eq(inbox[1].from, "farm", "newest first")
    t.eq(inbox[3].subject, "lunch")
    t.eq(handlers.unread(BOB, {}).unread, 3)
    t.ok(handlers.read(BOB, { id = inbox[3].id }))
    t.eq(handlers.unread(BOB, {}).unread, 2)
    t.ok(handlers.delete(BOB, { id = inbox[1].id }))
    t.eq(#handlers.list(BOB, {}), 2)
    -- (a message to a group has one id for everyone; carol never got bob's lunch mail)
    t.ok(not handlers.delete(CAROL, { id = inbox[3].id }), "not carol's message")

    local sent_box = handlers.list(CAROL, { folder = "sent" })
    t.eq(#sent_box, 1, "carol's sent folder")
    t.eq(sent_box[1].to, "bob")
    t.eq(#handlers.list(CAROL, {}), 1, "and her inbox has the miners message")
    t.ok(not handlers.list(CAROL, { folder = "trash" }))
    cleanup()
  end)

  t.it("the mail app lays out folders, list and reading pane", function()
    local app = t.fresh_import()("mail_app")
    local wide = app.layout(51, 19)
    t.ok(wide.is_wide)
    t.ok(wide.list.x > wide.folders.w, "the list is right of the folders")
    t.ok(wide.preview.y > wide.list.y + wide.list.h - 1, "the reading pane is below the list")
    t.ok(wide.preview.y + wide.preview.h - 1 <= 17, "above the status line and hints")
    local narrow = app.layout(26, 20)
    t.ok(not narrow.is_wide, "pocket computers: one thing at a time")
    local message = { from = "bob", to = "carol", subject = "lunch", text = "pizza?",
      time = 1000, is_read = false }
    local line = app.list_line(message, "inbox", 30, 1000 + 7200)
    t.eq(#line, 30)
    t.ok(line:find("^%*bob"), line)
    t.ok(line:find("lunch"), line)
    t.ok(line:find("2h$"), line)
    t.ok(app.list_line(message, "sent", 48):find("to carol"), "the sent folder shows who to")
    t.eq(app.reply_subject(message), "Re: lunch")
    t.eq(app.reply_subject({ subject = "Re: lunch" }), "Re: lunch", "not Re: Re:")
    t.eq(app.subject({ text = "no\nsubject  here" }), "no subject here")
  end)
end
