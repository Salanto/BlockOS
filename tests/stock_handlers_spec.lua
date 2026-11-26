-- The stock computer's request handlers: access list and changes; and the TUI.
return function(t)
  local USERS = {
    ["alice-token"] = { name = "alice", groups = { "domain-users" } },
    ["bob-token"] = { name = "bob", groups = { "domain-users", "kitchen" } },
    ["eve-token"] = { name = "eve", groups = { "domain-users" } },
    ["root-token"] = { name = "root", groups = { "domain-users", "domain-admins" } },
  }
  local COMPUTERS = { ["board-token"] = { hostname = "board-pc" } }

  -- A stock computer whose admin is alice and whose viewers are group kitchen.
  local function new_monitor()
    local import = t.fresh_import()
    local rpc = import("rpc")
    rpc.set_user_validator(function(token) return USERS[token] end)
    rpc.set_computer_validator(function(token) return COMPUTERS[token] end)
    local stock = import("stock")
    local monitor = {
      config = stock.new_config({ "alice" }),
      totals = {
        ["minecraft:iron_ingot"] = { count = 40, label = "Iron Ingot" },
        ["minecraft:cobblestone"] = { count = 640, label = "Cobblestone" },
      },
      states = {},
      alerts = {},
      saves = 0,
    }
    monitor.config.access.viewers = { "kitchen" }
    function monitor.save()
      monitor.saves = monitor.saves + 1
      return true
    end
    function monitor.snapshot()
      return { title = "Stock", rows = stock.sorted_rows(monitor.states) }
    end
    function monitor.list_outputs()
      return { { target = "computer", sides = stock.SIDES } }
    end
    return monitor, import("stock_handlers").new(monitor), import
  end

  local function as(token)
    return { sender = 5, token = token }
  end

  t.it("the access list decides who may look and who may change", function()
    local monitor, handlers = new_monitor()
    local watch = { item = "minecraft:iron_ingot", limit = 20 }
    t.ok(handlers.watch(as("alice-token"), watch), "admins may change")
    t.ok(handlers.watch(as("root-token"), watch), "domain admins may change")
    local _, err = handlers.watch(as("bob-token"), watch)
    t.eq(err, "permission denied", "viewers may not change")
    t.ok(handlers.status(as("bob-token")), "viewers may look")
    _, err = handlers.status(as("eve-token"))
    t.eq(err, "permission denied", "others may not even look")
    _, err = handlers.status({ sender = 5 })
    t.ok(err, "anonymous callers are refused")
    t.eq(monitor.saves, 2)
  end)

  t.it("only listed computers may pull data headlessly", function()
    local monitor, handlers = new_monitor()
    local board = { sender = 9, computer_token = "board-token" }
    t.ok(not handlers.status(board))
    monitor.config.access.computers = { "board-pc" }
    t.ok(handlers.status(board))
    t.ok(not handlers.catalog(board), "the catalog needs a user")
  end)

  t.it("a local admin at the stock computer is always an admin", function()
    local monitor, handlers = new_monitor()
    monitor.config.access.admins = {}
    t.ok(handlers.set_access({ local_admin = true }, { admins = { "bob" } }))
    t.eq(monitor.config.access.admins[1], "bob")
  end)

  t.it("watch, watch_all, unwatch and settings change the config", function()
    local monitor, handlers = new_monitor()
    local alice = as("alice-token")
    t.ok(handlers.watch(alice, { item = "minecraft:iron_ingot", limit = 25 }))
    t.eq(monitor.config.watches["minecraft:iron_ingot"].label, "Iron Ingot")
    local _, err = handlers.watch(alice, { item = "x", limit = "lots" })
    t.ok(err:find("bad request"), err)
    t.eq(handlers.watch_all(alice, { share = 0.5 }).added, 1)
    t.eq(monitor.config.watches["minecraft:cobblestone"].limit, 320)
    t.ok(handlers.unwatch(alice, { item = "minecraft:cobblestone" }))
    t.ok(handlers.settings(alice, { chime = false, sound = { kind = "sound", value = "x:y" } }))
    t.eq(monitor.config.chime, false)
    t.eq(monitor.config.sound.kind, "sound")
    t.ok(not handlers.settings(alice, { sound = { kind = "radio", value = "x" } }))
    t.ok(handlers.watch(alice, { item = "minecraft:iron_ingot", limit = 25, refill_to = 400 }))
    t.eq(monitor.config.watches["minecraft:iron_ingot"].refill_to, 400)
    t.ok(handlers.watch(alice, { item = "minecraft:iron_ingot", limit = 30 }), "keeps refill")
    t.eq(monitor.config.watches["minecraft:iron_ingot"].refill_to, 400)
    t.ok(handlers.watch(alice, { item = "minecraft:iron_ingot", limit = 30, refill_to = 0 }))
    t.eq(monitor.config.watches["minecraft:iron_ingot"].refill_to, nil, "0 clears it")
  end)

  t.it("the stock tool watches an item from the Catalog tab", function()
    local monitor, handlers, import = new_monitor()
    _G.blockos = {
      ui = import("ui"),
      user = { name = "admin", source = "local", is_admin = true },
      stock_server = { handlers = handlers, monitor = monitor, config = monitor.config },
    }
    local input = {
      { "wait", 0.3 }, { "char", "2" }, { "wait", 0.3 },
      { "key", keys.down }, -- Iron Ingot (Cobblestone sorts first)
      { "char", "w" },
      { "paste", "12" }, { "key", keys.enter },
      { "wait", 0.3 }, { "char", "q" },
    }
    t.with_input(function()
      shell.run(fs.combine(t.repo, "packages/storage-monitor/files/blockos/bin/stock.lua"))
    end, input)
    local watch = monitor.config.watches["minecraft:iron_ingot"]
    t.ok(watch, "iron was not watched")
    t.eq(watch.limit, 12)
  end)
end
