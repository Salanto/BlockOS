-- Alerts: the client library (building and raising alerts), the hub (routing, repeats,
-- "ok", queues and retries), the channel kinds, the hub's handlers and logistics level
-- alerts reaching it.
return function(t)
  local function new_alerts()
    local import = t.fresh_import()
    local alerts = import("alerts")
    alerts.env.now = function() return 1000 end
    return alerts, import
  end

  -- A hub with stub channel kinds that record what they got. `fail[name]` makes a
  -- channel's deliveries fail.
  local function new_hub(channels)
    local alerts, import = new_alerts()
    local alerts_hub = import("alerts_hub")
    local now = 0
    alerts_hub.env.clock = function() return now end
    local got, fail = {}, {}
    local function recorder(kind)
      return {
        kind = kind,
        help = "stub",
        check = function(target)
          if target == "bad" then
            return nil, "bad target"
          end
          return true
        end,
        describe = function(target) return kind .. " " .. target end,
        deliver = function(target, alert)
          if fail[target] then
            return nil, "down"
          end
          got[#got + 1] = { target = target, alert = alert }
          return true
        end,
      }
    end
    local config = { channels = {} }
    for name, channel in pairs(channels or {}) do
      channel.name = name
      channel.target = channel.target or name
      channel.kind = channel.kind or "stub"
      config.channels[name] = channel
    end
    local saves, wakes = 0, 0
    local hub = alerts_hub.new({
      kinds = { stub = recorder("stub") },
      config = config,
      save = function()
        saves = saves + 1
        return true
      end,
      wake = function() wakes = wakes + 1 end,
    })
    local state = {
      got = got,
      fail = fail,
      advance = function(seconds) now = now + seconds end,
      saves = function() return saves end,
      wakes = function() return wakes end,
    }
    return hub, state, alerts, alerts_hub, import
  end

  local function alert(alerts, fields)
    return assert(alerts.alert(fields))
  end

  t.it("an alert is completed and checked before it goes out", function()
    local alerts = new_alerts()
    local built = assert(alerts.alert({ source = "reactor", title = string.rep("x", 200) }))
    t.eq(built.level, "warn", "warn by default")
    t.eq(#built.title, alerts.MAX_TITLE, "long titles are cut")
    t.eq(built.time, 1000)
    t.ok(type(built.host) == "string")
    local _, err = alerts.alert({ source = "reactor", level = "panic", title = "x" })
    t.ok(err and err:find("level"), tostring(err))
    _, err = alerts.alert({ level = "info", title = "no source" })
    t.ok(err and err:find("source"), tostring(err))
    local event = assert(alerts.event({ source = "a", level = "ok", title = "fine" }))
    t.eq(alerts.parse(event).title, "fine")
    t.eq(alerts.parse({ v = 1, kind = "event", topic = "other", data = {} }), nil)
    t.eq(alerts.rank("error"), 3)
    t.eq(alerts.rank("ok"), 0)
  end)

  t.it("raising sends one event to the hub; a missing hub is remembered", function()
    local alerts = new_alerts()
    local finds, sent = 0, {}
    local hub_id = nil
    alerts.env.find = function()
      finds = finds + 1
      return hub_id
    end
    alerts.env.send = function(id, message, protocol)
      sent[#sent + 1] = { id = id, message = message, protocol = protocol }
    end
    local clock = 0
    alerts.env.clock = function() return clock end
    local ok, err = alerts.raise({ source = "a", title = "x" })
    t.ok(not ok and err:find("no alert hub"), tostring(err))
    alerts.raise({ source = "a", title = "x" })
    t.eq(finds, 1, "not looked for again at once")
    clock, hub_id = 61, 5
    t.ok(alerts.raise({ source = "a", level = "error", title = "boom" }))
    t.eq(#sent, 1)
    t.eq(sent[1].id, 5)
    t.eq(sent[1].protocol, alerts.PROTOCOL)
    t.eq(alerts.parse(sent[1].message).level, "error")
    local _, bad = alerts.raise({ source = "a", level = "nope", title = "x" })
    t.ok(bad and bad:find("level"), "a bad alert is refused before sending")
  end)

  t.it("channels get alerts by level and source", function()
    local hub, state, alerts = new_hub({
      discord = { min_level = "warn" },
      everything = { min_level = "info" },
      reactor_only = { min_level = "info", sources = { "reactor" } },
    })
    t.eq(hub.receive(alert(alerts, { source = "farm", level = "info", title = "a" })).queued, 1,
      "only the channel taking info from every source")
    t.eq(hub.receive(alert(alerts, { source = "reactor", level = "error", title = "b" })).queued,
      3)
    t.eq(state.wakes(), 2)
    hub.deliver_due()
    t.eq(#state.got, 3, "one per channel per round")
    state.advance(1)
    hub.deliver_due()
    t.eq(#state.got, 4, "the second alert of the busy channel")
    t.eq(hub.deliver_due(), nil, "nothing waits")
    t.eq(#hub.history, 2)
  end)

  t.it("repeats wait, level changes go at once, ok only for active problems", function()
    local hub, _, alerts, alerts_hub = new_hub({ all = { min_level = "info" },
      quiet = { min_level = "info", resolved = false } })
    local hot = { source = "reactor", key = "heat", level = "warn", title = "hot" }
    t.eq(hub.receive(alert(alerts, hot)).queued, 2)
    local again = hub.receive(alert(alerts, hot))
    t.ok(again.is_repeat, "the same level again is not sent")
    t.eq(#hub.active_list(), 1)
    hot.level = "error"
    t.eq(hub.receive(alert(alerts, hot)).queued, 2, "worse: sent at once")
    alerts_hub.env.clock = function() return alerts_hub.REPEAT_SECONDS + 1 end
    t.eq(hub.receive(alert(alerts, hot)).queued, 2, "a reminder after a while")
    local ok = { source = "reactor", key = "heat", level = "ok", title = "cool" }
    t.eq(hub.receive(alert(alerts, ok)).queued, 1, "not to channels without resolved")
    t.eq(#hub.active_list(), 0)
    t.ok(hub.receive(alert(alerts, ok)).is_repeat, "nothing was active: not sent")
  end)

  t.it("failed deliveries are retried, then dropped; queues are capped", function()
    local hub, state, alerts, alerts_hub = new_hub({ down = {} })
    state.fail.down = true
    hub.receive(alert(alerts, { source = "a", title = "x" }))
    local wait = hub.deliver_due()
    t.eq(wait, alerts_hub.RETRY_SECONDS)
    local listed = hub.list().channels[1]
    t.eq(listed.last_error, "down")
    t.eq(listed.queued, 1)
    for _ = 2, alerts_hub.MAX_ATTEMPTS do
      state.advance(alerts_hub.RETRY_SECONDS)
      hub.deliver_due()
    end
    listed = hub.list().channels[1]
    t.eq(listed.queued, 0, "given up")
    t.eq(listed.dropped, 1)
    t.eq(listed.failed, alerts_hub.MAX_ATTEMPTS)
    for index = 1, alerts_hub.MAX_QUEUE + 3 do
      hub.receive(alert(alerts, { source = "a", key = "k" .. index, title = "x" }))
    end
    t.eq(hub.list().channels[1].queued, alerts_hub.MAX_QUEUE)
    state.fail.down = nil
    state.advance(alerts_hub.RETRY_SECONDS)
    hub.deliver_due()
    t.eq(state.got[1].alert.key, "k4", "the oldest were dropped")
  end)

  t.it("channels are added, checked, listed without their target, and removed", function()
    local hub, state, alerts = new_hub()
    local _, err = hub.set_channel({ name = "x", kind = "pager", target = "1" })
    t.ok(err and err:find("unknown channel kind") and err:find("stub"), tostring(err))
    _, err = hub.set_channel({ name = "x", kind = "stub", target = "bad" })
    t.eq(err, "bad target")
    t.ok(hub.set_channel({ name = "ops", kind = "stub", target = "secret", min_level = "error",
      sources = { "reactor", "", 5 } }))
    t.eq(state.saves(), 1)
    local listed = hub.list()
    t.eq(listed.channels[1].target, nil, "never shown")
    t.eq(listed.channels[1].describe, "stub secret")
    t.eq(#listed.channels[1].sources, 1, "only real source names")
    t.eq(listed.kinds[1].kind, "stub")
    t.eq(hub.receive(alert(alerts, { source = "reactor", level = "warn", title = "x" })).queued,
      0, "below the channel's level")
    t.ok(hub.test("ops"))
    t.eq(state.got[1].alert.title, "Test alert", "a test skips the filters")
    t.ok(not hub.test("nope"))
    t.ok(hub.del_channel("ops"))
    t.ok(not hub.del_channel("ops"))
    t.eq(#hub.list().channels, 0)
  end)

  t.it("the handlers check arguments, guard channels in a domain, and fill the host", function()
    local hub, state, _, alerts_hub, import = new_hub({ all = { min_level = "info" } })
    local roles = import("roles")
    local is_joined = false
    roles.env.is_joined = function() return is_joined end
    roles.env.group_get = function() return { name = "alerts-admins", everyone = false } end
    roles.env.require_user = function() return nil, "permission denied" end
    roles.clear_cache()
    local handlers = alerts_hub.handlers(hub)
    local result = handlers.raise({ sender = 9 }, { source = "a", level = "info", title = "x" })
    t.eq(result.queued, 1)
    t.eq(hub.history[1].host, "#9", "the sender when the alert says nothing")
    local _, err = handlers.raise({ sender = 9 }, { source = "a", level = "info" })
    t.ok(err and err:find("bad request"), tostring(err))
    t.ok(handlers.channel_set({ sender = 9 }, { name = "b", kind = "stub", target = "t" }),
      "open without a domain")
    is_joined = true
    _, err = handlers.channel_set({ sender = 9, token = "x" },
      { name = "c", kind = "stub", target = "t" })
    t.eq(err, "permission denied", "managed: alerts-admins only")
    t.ok(handlers.list({ sender = 9 }).channels, "reading stays open")
    t.eq(state.saves(), 1)
    local message = assert(import("alerts").event({ source = "a", level = "error",
      title = "y", host = "farm" }))
    t.eq(alerts_hub.on_message(hub, 4, message).queued, 2)
    t.eq(hub.history[2].host, "farm")
    t.eq(alerts_hub.on_message(hub, 4, { hello = true }), nil, "not an alert")
  end)

  t.it("the channel kinds: discord, webhook, mail and computer", function()
    local alerts, import = new_alerts()
    local kinds = import("alerts_hub").load_kinds(t.repo .. "/packages/alerts-hub/files/blockos",
      import)
    for _, name in ipairs({ "discord", "webhook", "mail", "computer" }) do
      t.ok(kinds[name], name .. " is loaded")
    end
    local sample = alert(alerts, { source = "logistics", level = "warn", title = "Iron is low",
      text = "3 of 64", host = "storage" })

    local discord = kinds.discord
    local url = "https://discord.com/api/webhooks/123456/abc-DEF_9"
    t.ok(discord.check(url))
    t.ok(discord.check("https://canary.discord.com/api/webhooks/1/x"))
    t.ok(not discord.check("https://example.com/api/webhooks/1/x"))
    t.ok(not discord.check("http://discord.com/api/webhooks/1/x"), "https only")
    t.eq(discord.describe(url), "Discord webhook 123456", "never the token")
    local posted = {}
    local env = {
      post = function(target, body)
        posted[#posted + 1] = { url = target, body = body }
        return true
      end,
    }
    t.ok(discord.deliver(url, sample, env))
    local embed = posted[1].body.embeds[1]
    t.eq(embed.title, "Iron is low")
    t.eq(embed.description, "3 of 64")
    t.eq(embed.color, 0xF1C40F)
    t.ok(embed.footer.text:find("logistics on storage"), embed.footer.text)
    t.ok(textutils.serializeJSON(posted[1].body):find("Iron is low"), "encodes as JSON")

    t.ok(kinds.webhook.check("http://192.0.2.1:8080/hook"))
    t.ok(not kinds.webhook.check("ftp://x"))
    t.eq(kinds.webhook.describe("https://hooks.example.com/secret/path"),
      "webhook hooks.example.com")
    t.ok(kinds.webhook.deliver("https://h/x", sample, env))
    t.eq(posted[2].body.level, "warn")
    t.eq(posted[2].body.host, "storage")

    local mailed = {}
    env.mail = function(to, subject, text)
      mailed[#mailed + 1] = { to = to, subject = subject, text = text }
      return { sent = 1 }
    end
    t.ok(kinds.mail.check("miners"))
    t.ok(not kinds.mail.check("two words"))
    t.ok(kinds.mail.deliver("miners", sample, env))
    t.eq(mailed[1].subject, "[warn] Iron is low")
    t.ok(mailed[1].text:find("3 of 64") and mailed[1].text:find("storage"), mailed[1].text)
    env.mail = function() return nil, "no mail server found" end
    local ok, err = kinds.mail.deliver("miners", sample, env)
    t.ok(not ok and err:find("mail server"))

    local sent, broadcasts = {}, {}
    env.send = function(id, message, protocol) sent[#sent + 1] = { id, message, protocol } end
    env.broadcast = function(_, protocol) broadcasts[#broadcasts + 1] = protocol end
    env.resolve = function(name) return name == "wall" and 12 or nil end
    local computer = kinds.computer
    t.ok(computer.deliver("#7", sample, env))
    t.ok(computer.deliver("wall", sample, env))
    t.eq(sent[1][1], 7)
    t.eq(sent[2][1], 12)
    t.eq(sent[2][3], alerts.NOTIFY_PROTOCOL)
    t.eq(alerts.parse(sent[2][2]).title, "Iron is low", "receivers read it with alerts.parse")
    t.ok(computer.deliver("everyone", sample, env))
    t.eq(broadcasts[1], alerts.NOTIFY_PROTOCOL)
    ok, err = computer.deliver("nowhere", sample, env)
    t.ok(not ok and err:find("nowhere"))
  end)

  t.it("logistics level alerts are raised for the alert hub", function()
    local import = t.fresh_import()
    import("roles").env.is_joined = function() return false end
    local alarms = import("logistics_alarms")
    alarms.env.broadcast = function() end
    alarms.env.redstone = { setOutput = function() end }
    local raised = {}
    local hub = import("logistics_hub").new({
      config = {},
      save = function() return true end,
      hostname = "controller",
      raise_alert = function(fields) raised[#raised + 1] = fields end,
    })
    local function report(count)
      hub.update("main", {
        totals = { ["minecraft:gold_ingot"] = { count = count, label = "Gold Ingot" } },
        blocks = { { handle = "chest_1", role = "storage" } },
        sources = 1,
      }, {})
    end
    report(9)
    local handlers = import("logistics_handlers").new(hub)
    t.ok(handlers.watch({ sender = 3 }, { item = "minecraft:gold_ingot", limit = 10 }))
    hub.check_levels()
    t.eq(#raised, 1)
    t.eq(raised[1].source, "logistics")
    t.eq(raised[1].key, "minecraft:gold_ingot")
    t.eq(raised[1].level, "warn")
    t.eq(raised[1].title, "Gold Ingot is low")
    t.ok(import("alerts").alert(raised[1]), "a valid alert")
    report(50)
    hub.check_levels()
    t.eq(raised[2].level, "ok", "recovered")
  end)

  -- Runs fn with a fresh `blockos` table (notices keep their state there).
  local function with_blockos(fn)
    local saved = _G.blockos
    _G.blockos = {}
    local ok, err = pcall(fn)
    _G.blockos = saved
    if not ok then
      error(err, 0)
    end
  end

  t.it("notices with a level are problems; failed services are one", function()
    with_blockos(function()
      local import = t.fresh_import()
      local notices = import("notices")
      notices.set("mail", "2 new messages")
      notices.set("disk", "The disk is nearly full", "warn")
      t.eq(#notices.list(), 2, "both are shown")
      local problems = notices.problems()
      t.eq(#problems, 1, "only the one with a level is a problem")
      t.eq(problems[1].key, "disk")
      t.eq(problems[1].level, "warn")
      notices.clear("disk")
      t.eq(#notices.problems(), 0)
      t.ok(not pcall(notices.set, "x", "y", "panic"), "only warn and error")

      local scheduler = import("scheduler").new()
      local services = import("services")
      services.init(scheduler)
      local is_broken = true
      services.register({
        name = "flaky",
        run = function()
          if is_broken then
            error("always broken", 0)
          end
          os.pullEvent("never")
        end,
      })
      services.start("flaky")
      for _ = 1, 10 do
        if services.state("flaky") ~= "restarting" then
          break
        end
        services.start("flaky")
      end
      problems = notices.problems()
      t.eq(#problems, 1)
      t.eq(problems[1].key, "service:flaky")
      t.eq(problems[1].level, "error")
      t.ok(problems[1].text:find("always broken"), problems[1].text)
      is_broken = false
      services.start("flaky")
      t.eq(#notices.problems(), 0, "running again: fixed")
    end)
  end)

  t.it("a problem tracker raises new problems and resolves gone ones", function()
    local alerts = new_alerts()
    local raised = {}
    local tracker = alerts.problem_tracker(function(fields) raised[#raised + 1] = fields end)
    local disk = { key = "disk", text = "Disk nearly full", level = "warn" }
    local service = { key = "service:mail-server", text = "Service mail-server failed",
      level = "error" }
    tracker.update("farm", { disk, service })
    t.eq(#raised, 2)
    t.eq(raised[1].key, "farm/disk")
    t.eq(raised[1].host, "farm", "the computer with the problem, not the broker")
    t.eq(raised[1].source, "system")
    t.ok(alerts.alert(raised[2]), "valid alerts")
    tracker.update("farm", { disk, service })
    t.eq(#raised, 2, "the same problems again: nothing new")
    tracker.update("mine", { disk })
    t.eq(raised[3].key, "mine/disk", "per computer")
    disk.level = "error"
    tracker.update("farm", { disk })
    t.eq(#raised, 5, "worse, and one gone")
    t.eq(raised[4].level, "error")
    t.eq(raised[5].level, "ok")
    t.eq(raised[5].key, "farm/service:mail-server")
    t.ok(raised[5].title:find("^Fixed: "), raised[5].title)
    tracker.forget("mine")
    tracker.update("mine", {})
    t.eq(#raised, 5, "a forgotten computer resolves nothing")
    tracker.update("farm", { { key = 5 }, "junk", { key = "a", text = "A" } })
    t.eq(#raised, 7, "bad entries are skipped")
    t.eq(raised[6].key, "farm/a")
    t.eq(raised[7].key, "farm/disk", "no longer reported: fixed")
    t.eq(raised[7].level, "ok")
  end)

  t.it("a sender raises from its own loop", function()
    local alerts = new_alerts()
    local raised = {}
    local sender = alerts.sender(function(fields)
      raised[#raised + 1] = fields
      error("a broken raise does not stop the loop")
    end)
    sender.raise({ title = "a" })
    sender.raise({ title = "b" })
    t.eq(#raised, 0, "nothing waits in the caller")
    parallel.waitForAny(sender.run, function() end)
    t.eq(#raised, 2)
    t.eq(raised[2].title, "b")
  end)

  t.it("the domain controller brokers computers' problems and silence", function()
    local import = t.fresh_import()
    local raised = {}
    local dc_alerts = import("dc_alerts")
    local broker = dc_alerts.new(function(fields) raised[#raised + 1] = fields end)
    broker.on_report("farm", { hostname = "farm" })
    t.eq(#raised, 0, "a report without problems changes nothing")
    broker.on_report("farm", { problems = { { key = "disk", text = "Full", level = "warn" } } })
    t.eq(raised[1].key, "farm/disk")
    broker.check_offline({ { hostname = "farm", age = 10 }, { hostname = "new" } })
    t.eq(#raised, 1, "recent, or not reported since the controller started")
    broker.check_offline({ { hostname = "farm", age = dc_alerts.OFFLINE_SECONDS + 1 } })
    t.eq(raised[2].level, "info")
    t.eq(raised[2].key, "farm/offline")
    broker.check_offline({ { hostname = "farm", age = dc_alerts.OFFLINE_SECONDS + 300 } })
    t.eq(#raised, 2, "once")
    broker.on_report("farm", { problems = {} })
    t.eq(raised[3].level, "ok", "back")
    t.eq(raised[4].key, "farm/disk", "and its problem fixed")
    t.eq(raised[4].level, "ok")
    broker.own_problems("dc", { { key = "dc_disk", text = "Nearly full", level = "warn" } })
    t.eq(raised[5].host, "dc")

    -- Status reports reach the broker through the host_update hook.
    local dir = assert(import("directory").create("home", "admin", "secret"))
    local storage = { save = function() return true end, has_room = function() return true end }
    local reports = {}
    local handlers = import("dc_handlers").new(dir, storage, nil, {
      on_report = function(hostname, args) reports[#reports + 1] = { hostname, args } end,
    })
    local joined = assert(handlers.join({ sender = 7 }, {
      hostname = "pc1", admin_name = "admin", admin_password = "secret",
    }))
    local computer = { sender = 7, computer_token = joined.computer_token }
    t.ok(handlers.host_update(computer, { hostname = "pc1",
      problems = { { key = "x", text = "X", level = "warn" } } }))
    t.eq(reports[1][1], "pc1")
    t.eq(reports[1][2].problems[1].key, "x")
    local _, err = handlers.host_update(computer, { hostname = "pc1", problems = "lots" })
    t.ok(err and err:find("bad request"), tostring(err))
  end)

  t.it("the logistics hub brokers silent nodes and failed crafting", function()
    local import = t.fresh_import()
    import("roles").env.is_joined = function() return false end
    local hub_module = import("logistics_hub")
    local now = 0
    hub_module.env.clock = function() return now end
    local raised = {}
    local hub = hub_module.new({
      config = {},
      save = function() return true end,
      hostname = "controller",
      raise_alert = function(fields) raised[#raised + 1] = fields end,
    })
    local function report(jobs)
      hub.update("ores", {
        totals = {},
        blocks = { { handle = "chest_1", role = "storage" } },
        sources = 1,
        poll_seconds = 10,
        crafting = jobs and { recipes = {}, jobs = jobs } or nil,
      }, {})
    end
    report({ { item = "minecraft:torch", state = "failed", note = "old", at = 100 } })
    t.eq(#raised, 0, "jobs from before the hub heard of the node are not raised")
    now = 31
    hub.check_nodes()
    t.eq(raised[1].level, "warn")
    t.eq(raised[1].key, "node/ores")
    t.eq(raised[1].source, "logistics")
    hub.check_nodes()
    t.eq(#raised, 1, "once")
    report({
      { item = "minecraft:torch", state = "failed", note = "missing coal", made = 2,
        count = 8, at = 200 },
      { item = "minecraft:torch", state = "failed", note = "old", at = 100 },
    })
    t.eq(raised[2].key, "craft/minecraft:torch")
    t.eq(raised[2].level, "warn")
    t.ok(raised[2].text:find("missing coal"), raised[2].text)
    t.eq(raised[3].key, "node/ores")
    t.eq(raised[3].level, "ok", "the node is back")
    report({ { item = "minecraft:torch", state = "done", at = 300 } })
    t.eq(raised[4].level, "ok", "crafting works again")
    t.ok(import("alerts").alert(raised[2]), "valid alerts")
  end)
end
