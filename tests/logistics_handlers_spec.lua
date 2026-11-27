-- The hub's request handlers: open standalone, roles in managed mode, private nodes,
-- changes; and the full-screen tool.
return function(t)
  local USERS = {
    ["alice-token"] = { name = "alice", groups = { "domain-users", "logistics-admins",
      "logistics-users" } },
    ["bob-token"] = { name = "bob", groups = { "domain-users", "logistics-users",
      "logistics-node-vault" } },
    ["eve-token"] = { name = "eve", groups = { "domain-users", "logistics-users" } },
    ["mallory-token"] = { name = "mallory", groups = { "domain-users" } },
    -- The directory adds everyone-groups to every user; root is only in those.
    ["root-token"] = { name = "root", groups = { "domain-users", "domain-admins",
      "logistics-users" } },
  }

  local function fake_proxy(calls)
    return {
      request = function(item, count, output)
        calls[#calls + 1] = { op = "request", item = item, count = count, output = output }
        return { moved = math.min(count, 40), output = output or "out" }
      end,
      set_storage = function(change)
        calls[#calls + 1] = { op = "set_storage", change = change }
        return { storage = change.storage }
      end,
      find_start = function() return true end,
      find_finish = function() return { { handle = "chest_2", label = "chest_2" } } end,
    }
  end

  -- A hub with two nodes: "main" (iron, an output) and "vault" (gold, private once
  -- its role exists). `groups` are the directory's roles (missing = not set up).
  local function new_hub(options)
    options = options or {}
    local import = t.fresh_import()
    local rpc = import("rpc")
    rpc.set_user_validator(function(token) return USERS[token] end)
    local roles = import("roles")
    roles.env = {
      is_joined = function() return options.joined == true end,
      group_get = function(name)
        local info = (options.groups or {})[name]
        if info then
          return info
        end
        return nil, "no such group"
      end,
      require_user = function(ctx, groups) return rpc.require_user(ctx, groups) end,
      installed = function() return {} end,
      clock = function() return 0 end,
    }
    local alarms = import("logistics_alarms")
    alarms.env.broadcast = function() end
    alarms.env.redstone = { setOutput = function() end }
    local saves = { count = 0 }
    local hub = import("logistics_hub").new({
      config = {},
      save = function()
        saves.count = saves.count + 1
        return true
      end,
      hostname = "controller",
    })
    local calls = {}
    hub.update("main", {
      totals = { ["minecraft:iron_ingot"] = { count = 40, label = "Iron Ingot" } },
      blocks = {
        { handle = "chest_1", label = "Ores", role = "storage", used = 1, size = 27 },
        { handle = "out", label = "Output", role = "output", used = 0, size = 27 },
      },
      moves = { { from = "pickup", to = "chest_1", item = "minecraft:iron_ingot", count = 5 } },
      sources = 1,
    }, fake_proxy(calls))
    hub.update("vault", {
      totals = { ["minecraft:gold_ingot"] = { count = 9, label = "Gold Ingot" } },
      blocks = { { handle = "chest_1", label = "Gold", role = "storage" } },
      sources = 1,
    }, fake_proxy(calls))
    local handlers = import("logistics_handlers").new(hub)
    return hub, handlers, calls, saves, import
  end

  local function as(token)
    return { sender = 5, token = token }
  end

  local IRON = { item = "minecraft:iron_ingot", limit = 20 }

  t.it("standalone, everything is open (friends only)", function()
    local hub, handlers, _, saves = new_hub()
    t.ok(handlers.status({ sender = 3 }), "anonymous callers may look")
    t.eq(#handlers.catalog({ sender = 3 }), 2, "items of both nodes")
    t.ok(handlers.watch({ sender = 3 }, IRON), "and change")
    t.eq(hub.config.watches["minecraft:iron_ingot"].label, "Iron Ingot")
    t.eq(saves.count, 1)
  end)

  t.it("joined but not set up, still open", function()
    local _, handlers = new_hub({ joined = true })
    t.ok(handlers.watch({ sender = 3 }, IRON))
  end)

  t.it("managed mode: users look and request, admins change", function()
    local groups = { ["logistics-admins"] = {}, ["logistics-users"] = {} }
    local _, handlers = new_hub({ joined = true, groups = groups })
    t.ok(handlers.status(as("eve-token")), "users may look")
    local _, err = handlers.status(as("mallory-token"))
    t.eq(err, "permission denied", "others may not")
    _, err = handlers.watch(as("eve-token"), IRON)
    t.eq(err, "permission denied", "users may not change levels")
    t.ok(handlers.watch(as("alice-token"), IRON), "logistics admins may")
    t.ok(handlers.watch(as("root-token"), IRON), "domain admins may")
    t.ok(handlers.watch({ local_admin = true }, IRON), "the local admin always may")
    local result = handlers.request(as("eve-token"), { item = "iron", count = 64 })
    t.eq(result.moved, 40)
    t.eq(result.node, "main")
  end)

  t.it("a private node is seen only by its role's members", function()
    local groups = {
      ["logistics-admins"] = {},
      ["logistics-users"] = { everyone = true },
      ["logistics-node-vault"] = {},
    }
    local _, handlers = new_hub({ joined = true, groups = groups })
    local function labels(token)
      local seen = {}
      for _, row in ipairs(handlers.catalog(as(token))) do
        seen[#seen + 1] = row.label
      end
      return table.concat(seen, ",")
    end
    t.eq(labels("eve-token"), "Iron Ingot", "eve does not see the vault")
    t.eq(labels("bob-token"), "Gold Ingot,Iron Ingot", "bob is in logistics-node-vault")
    t.eq(labels("root-token"), "Gold Ingot,Iron Ingot", "domain admins see everything")
    local _, err = handlers.request(as("eve-token"), { item = "gold", count = 1 })
    t.ok(err, "eve cannot request from the vault")
    for _, row in ipairs(handlers.storages(as("eve-token"))) do
      t.eq(row.node, "main")
    end
  end)

  t.it("requests go to the node that has the item and an output", function()
    local _, handlers, calls = new_hub()
    local result = assert(handlers.request({ sender = 3 }, { item = "iron", count = 10 }))
    t.eq(result.node, "main")
    t.eq(result.label, "Iron Ingot")
    t.eq(calls[1].item, "minecraft:iron_ingot")
    local _, err = handlers.request({ sender = 3 }, { item = "gold", count = 1 })
    t.ok(err:find("output"), "the vault has no output: " .. tostring(err))
    local catalog = handlers.catalog({ sender = 3 })
    t.eq(catalog[2].count, 30, "counts drop at once after a request")
  end)

  t.it("chests are named by label, name or node/name", function()
    local _, handlers, calls = new_hub()
    local _, err = handlers.set_storage({ sender = 3 }, { storage = "chest_1", role = "input" })
    t.ok(err:find("ambiguous"), "both nodes have chest_1: " .. tostring(err))
    local result = assert(handlers.set_storage({ sender = 3 },
      { storage = "vault/chest_1", role = "input" }))
    t.eq(result.node, "vault")
    t.eq(calls[#calls].change.storage, "chest_1")
    t.ok(not handlers.set_storage({ sender = 3 }, { storage = "gold", role = "bin" }),
      "unknown roles are refused")
    local storages = handlers.storages({ sender = 3 })
    for _, row in ipairs(storages) do
      if row.node == "vault" then
        t.eq(row.role, "input", "the change shows at once")
      end
    end
  end)

  t.it("watch, watch_all, unwatch and settings change the levels", function()
    local hub, handlers = new_hub()
    local ctx = { sender = 3 }
    t.ok(handlers.watch(ctx, { item = "minecraft:iron_ingot", limit = 25 }))
    local _, err = handlers.watch(ctx, { item = "x", limit = "lots" })
    t.ok(err:find("bad request"), err)
    t.eq(handlers.watch_all(ctx, { share = 0.5 }).added, 1, "gold, from the other node")
    t.eq(hub.config.watches["minecraft:gold_ingot"].limit, 4)
    t.ok(handlers.unwatch(ctx, { item = "minecraft:gold_ingot" }))
    t.ok(handlers.settings(ctx, { chime = false, sound = { kind = "sound", value = "x:y" } }))
    t.eq(hub.config.chime, false)
    t.ok(not handlers.settings(ctx, { sound = { kind = "radio", value = "x" } }))
    t.ok(handlers.watch(ctx, { item = "minecraft:iron_ingot", limit = 25, refill_to = 400 }))
    t.ok(handlers.watch(ctx, { item = "minecraft:iron_ingot", limit = 30 }), "keeps refill")
    t.eq(hub.config.watches["minecraft:iron_ingot"].refill_to, 400)
    t.ok(handlers.watch(ctx, { item = "minecraft:iron_ingot", limit = 30, refill_to = 0 }))
    t.eq(hub.config.watches["minecraft:iron_ingot"].refill_to, nil, "0 clears it")
  end)

  t.it("levels use the totals of every node and raise alerts", function()
    local hub, handlers = new_hub()
    t.ok(handlers.watch({ sender = 3 }, { item = "minecraft:gold_ingot", limit = 10 }))
    hub.check_levels()
    t.eq(hub.states["minecraft:gold_ingot"].is_low, true, "9 of 10")
    t.eq(#hub.alerts, 1)
    t.eq(hub.alerts[1].server, "controller")
    local rows = handlers.status({ sender = 3 }).rows
    t.eq(rows[1].label, "Gold Ingot")
  end)

  t.it("nodes are listed, go stale and can be forgotten", function()
    local import = t.fresh_import()
    local hub_module = import("logistics_hub")
    local now = 0
    hub_module.env.clock = function() return now end
    local hub = hub_module.new({ config = {}, save = function() return true end })
    hub.update("main", { totals = {}, blocks = { { handle = "a", role = "storage" } },
      poll_seconds = 10 }, {})
    t.eq(hub.list_nodes()[1].is_stale, false)
    now = 31
    t.eq(hub.list_nodes()[1].is_stale, true, "three rounds without a report")
    t.ok(hub.forget_node("main"))
    t.eq(#hub.list_nodes(), 0)
  end)

  t.it("the move log hands out moves newer than asked, with their node", function()
    local hub, handlers = new_hub()
    local ctx = { sender = 3 }
    local first = handlers.moves(ctx, {})
    t.eq(#first.moves, 1)
    t.eq(first.moves[1].node, "main")
    t.eq(first.moves[1].label, "Iron Ingot")
    hub.update("main", { totals = {}, blocks = {},
      moves = { { from = "chest_1", to = "out", item = "minecraft:iron_ingot", count = 6 } } }, {})
    local newer = handlers.moves(ctx, { since = first.seq })
    t.eq(#newer.moves, 1)
    t.eq(newer.moves[1].to, "out")
  end)

  t.it("the logistics tool watches an item from the Catalog tab", function()
    local hub, handlers, _, _, import = new_hub()
    _G.blockos = {
      ui = import("ui"),
      user = { name = "admin", source = "local", is_admin = true },
      logistics_hub = { hub = hub, handlers = handlers, config = hub.config },
    }
    local input = {
      { "wait", 0.3 }, { "char", "2" }, { "wait", 0.3 },
      { "key", keys.down }, -- Iron Ingot (Gold Ingot sorts first)
      { "char", "w" },
      { "paste", "12" }, { "key", keys.enter },
      { "wait", 0.3 }, { "char", "q" },
    }
    t.with_input(function()
      shell.run(fs.combine(t.repo, "packages/logistics/files/blockos/bin/logistics.lua"))
    end, input)
    local watch = hub.config.watches["minecraft:iron_ingot"]
    t.ok(watch, "iron was not watched")
    t.eq(watch and watch.limit, 12)
  end)
end
