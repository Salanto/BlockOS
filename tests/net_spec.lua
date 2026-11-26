-- The peer table and wire format.
return function(t)
  local function announce(fields)
    local message = { v = 1, hostname = "alpha", kind = "computer", version = "0.1.0" }
    for key, value in pairs(fields or {}) do
      message[key] = value
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
    t.eq(message.v, net.WIRE_VERSION)
    t.eq(message.info.fuel, 500)
    t.ok(message.hello)
    t.ok(net.is_valid_announce(message))
  end)
end
