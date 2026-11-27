-- The peer table and wire format.
return function(t)
  local ENVELOPE_FIELDS = { v = true, kind = true, topic = true }

  -- An announce event; envelope fields (v, kind, topic) can be overridden too.
  local function announce(fields)
    local message = {
      v = 1, kind = "event", topic = "announce",
      data = { hostname = "alpha", kind = "computer", version = "0.1.0" },
    }
    for key, value in pairs(fields or {}) do
      if ENVELOPE_FIELDS[key] then
        message[key] = value
      else
        message.data[key] = value
      end
    end
    return message
  end

  local function fresh_net()
    local net = t.fresh_import()("net")
    net.reset()
    return net
  end

  t.it("accepts valid announces and lists the peer", function()
    local net = fresh_net()
    t.ok(net.handle_announce(5, announce(), 100))
    local peers = net.peers(110)
    t.eq(#peers, 1)
    t.eq(peers[1].hostname, "alpha")
    t.eq(peers[1].id, 5)
    t.eq(peers[1].age, 10)
  end)

  t.it("drops announces from a newer wire version and malformed ones", function()
    local net = fresh_net()
    t.ok(not net.handle_announce(1, announce({ v = 2 })))
    t.ok(not net.handle_announce(1, announce({ v = "1" })))
    t.ok(not net.handle_announce(1, announce({ hostname = "" })))
    t.ok(not net.handle_announce(1, announce({ info = "not a table" })))
    t.ok(not net.handle_announce(1, "just a string"))
    t.eq(#net.peers(0), 0)
  end)

  t.it("ignores unknown fields", function()
    local net = fresh_net()
    t.ok(net.handle_announce(1, announce({ some_future_field = { 1, 2 } })))
  end)

  t.it("forgets peers that stop announcing", function()
    local net = fresh_net()
    net.handle_announce(1, announce(), 0)
    t.eq(#net.peers(net.PEER_EXPIRY_SECONDS - 1), 1)
    t.eq(#net.peers(net.PEER_EXPIRY_SECONDS + 1), 0)
  end)

  t.it("resolves names from the peer table", function()
    local net = fresh_net()
    net.handle_announce(42, announce({ hostname = "storage" }), os.clock())
    t.eq(net.resolve("storage"), 42)
    t.eq(net.resolve("STORAGE"), 42, "names are case-insensitive")
  end)

  t.it("sanitizes hostnames", function()
    local net = fresh_net()
    t.eq(net.sanitize("My Base #1"), "my-base--1")
    t.eq(net.sanitize(""), nil)
    t.eq(net.sanitize("localhost"), nil)
    t.eq(#net.sanitize(string.rep("x", 40)), 32)
  end)

  t.it("announces carry extra info set by services", function()
    local net = fresh_net()
    net.set_current_hostname("me")
    net.set_info("fuel", 500)
    local message = net.build_announce(true)
    t.eq(message.kind, "event")
    t.eq(message.topic, "announce")
    t.eq(message.data.info.fuel, 500)
    t.ok(message.data.hello)
    t.ok(net.parse_announce(message))
  end)

  t.it("chat messages are wire events with a sender and capped text", function()
    local import = t.fresh_import()
    local messages = import("messages")
    _G.blockos = { user = { name = "alice" } }
    local event = messages.event(string.rep("x", 500))
    t.ok(import("wire").parse(event, "event", messages.SCHEMA))
    t.eq(event.data.from, "alice@#" .. os.getComputerID())
    t.eq(#event.data.text, messages.MAX_LENGTH)
  end)

  t.it("closed modem sides are remembered and can be opened again", function()
    local net = fresh_net()
    local before = settings.get("blockos.net.closed_sides")
    net.close_side("left")
    net.close_side("back")
    t.ok(net.is_closed_side("left"))
    t.ok(net.is_closed_side("back"))
    t.ok(not net.is_closed_side("right"))
    net.close_side("left", true)
    t.ok(not net.is_closed_side("left"), "allowed again")
    t.ok(net.is_closed_side("back"))
    if before == nil then
      settings.unset("blockos.net.closed_sides")
    else
      settings.set("blockos.net.closed_sides", before)
    end
  end)

  t.it("discovery caches answers for a minute and forgets on request", function()
    local import = t.fresh_import()
    local domain = import("domain")
    local asked = 0
    domain.is_joined = function() return true end
    domain.find_service = function(service_type)
      asked = asked + 1
      return { id = 42, host = "storage-" .. service_type }
    end
    local discovery = import("discovery")
    local now = 0
    discovery.env.clock = function() return now end
    t.eq(discovery.find("pkg", "blockos.pkg"), 42)
    t.eq(discovery.find("pkg", "blockos.pkg"), 42)
    t.eq(asked, 1, "the second answer came from the cache")
    now = 61
    discovery.find("pkg", "blockos.pkg")
    t.eq(asked, 2, "after a minute it asks again")
    discovery.forget("pkg")
    discovery.find("pkg", "blockos.pkg")
    t.eq(asked, 3, "forget looks again at once")
  end)
end
