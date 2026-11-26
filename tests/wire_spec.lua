-- The shared message envelope and schema checks.
return function(t)
  t.it("validates fields by type, optional, max, min and one_of", function()
    local wire = t.fresh_import()("wire")
    local schema = {
      name = { type = "string", max = 5 },
      count = { type = "number", min = 0, optional = true },
      mode = { type = "string", one_of = { "a", "b" }, optional = true },
      flag = "boolean",
    }
    t.ok(wire.validate({ name = "abc", flag = true }, schema))
    t.ok(wire.validate({ name = "abc", flag = false, count = 3, mode = "b" }, schema))
    local _, err = wire.validate({ flag = true }, schema)
    t.ok(err:find("name is missing"), err)
    _, err = wire.validate({ name = 5, flag = true }, schema)
    t.ok(err:find("should be a string"), err)
    _, err = wire.validate({ name = "toolong", flag = true }, schema)
    t.ok(err:find("longer than 5"), err)
    _, err = wire.validate({ name = "a", flag = true, count = -1 }, schema)
    t.ok(err:find("below 0"), err)
    _, err = wire.validate({ name = "a", flag = true, mode = "c" }, schema)
    t.ok(err:find("unknown value"), err)
    t.ok(not wire.validate("not a table", schema))
  end)

  t.it("parses events, requests and responses by kind and version", function()
    local wire = t.fresh_import()("wire")
    local event = wire.event("ping", { n = 1 })
    t.ok(wire.parse(event, "event", { n = "number" }))
    t.ok(not wire.parse(event, "request"), "wrong kind")
    t.ok(not wire.parse(event, "event", { n = "string" }), "payload mismatch")
    local newer = wire.event("ping", {})
    newer.v = 2
    t.ok(not wire.parse(newer, "event"), "newer major version")
    t.ok(wire.parse(wire.request("1", "op", { a = 1 }), "request", { a = "number" }))
    t.ok(wire.parse(wire.response("1", true, { b = "x" }), "response", { b = "string" }))
    t.ok(wire.parse(wire.response("1", false, "no"), "response"))
    local extra = wire.event("ping", { n = 1, future = true })
    extra.also_future = 1
    t.ok(wire.parse(extra, "event", { n = "number" }), "unknown fields are ignored")
  end)

  t.it("rpc.with_args rejects bad arguments before the handler runs", function()
    local rpc = t.fresh_import()("rpc")
    local ran = false
    local handler = rpc.with_args({ name = "string" }, function(_, args)
      ran = true
      return args.name
    end)
    local _, err = handler({}, { name = 42 })
    t.ok(err:find("bad request"), err)
    t.ok(not ran)
    t.eq(handler({}, { name = "ok" }), "ok")
  end)
end
