-- Turtle remote control: handlers against a stub turtle (CraftOS-PC has none).
return function(t)
  local USERS = { ["alice-token"] = { name = "alice", groups = { "domain-users" } } }

  -- A stub turtle that records calls; moving forward fails when blocked.
  local function stub_turtle()
    local stub = { calls = {}, selected = 1, is_blocked = false }
    local function record(name, result, detail)
      stub[name] = function()
        stub.calls[#stub.calls + 1] = name
        return result, detail
      end
    end
    record("back", true)
    record("turnLeft", true)
    record("dig", false, "Nothing to dig here")
    stub.forward = function()
      stub.calls[#stub.calls + 1] = "forward"
      if stub.is_blocked then
        return false, "Movement obstructed"
      end
      return true
    end
    stub.select = function(slot)
      stub.selected = slot
      return true
    end
    stub.getSelectedSlot = function() return stub.selected end
    stub.getItemCount = function(slot) return slot == 1 and 5 or 0 end
    stub.getFuelLevel = function() return 80 end
    stub.getFuelLimit = function() return 20000 end
    return stub
  end

  local function new_handlers()
    local import = t.fresh_import()
    import("rpc").set_user_validator(function(token) return USERS[token] end)
    local turtle_api = stub_turtle()
    return import("turtle_remote").handlers(turtle_api), turtle_api
  end

  local ALICE = { sender = 3, token = "alice-token" }

  t.it("only logged-in domain users may drive", function()
    local handlers, turtle_api = new_handlers()
    t.ok(not handlers.act({ sender = 3 }, { action = "forward" }), "no login")
    t.ok(not handlers.act({ sender = 3, token = "forged" }, { action = "forward" }))
    t.ok(not handlers.info({ sender = 3 }), "info needs a login too")
    t.eq(#turtle_api.calls, 0, "nothing moved")
  end)

  t.it("actions run and return the turtle's new state", function()
    local handlers, turtle_api = new_handlers()
    local result = handlers.act(ALICE, { action = "forward" })
    t.ok(result.ok)
    t.eq(turtle_api.calls[1], "forward")
    t.eq(result.info.fuel, 80)
    t.eq(result.info.slots[1], 5)
    t.ok(handlers.act(ALICE, { action = "turn_left" }).ok)
    t.eq(turtle_api.calls[2], "turnLeft")
  end)

  t.it("a blocked move reports why instead of failing the request", function()
    local handlers, turtle_api = new_handlers()
    turtle_api.is_blocked = true
    local result = handlers.act(ALICE, { action = "forward" })
    t.eq(result.ok, false)
    t.eq(result.detail, "Movement obstructed")
    t.eq(handlers.act(ALICE, { action = "dig" }).detail, "Nothing to dig here")
  end)

  t.it("select changes the slot; unknown actions are refused", function()
    local handlers, turtle_api = new_handlers()
    t.eq(handlers.act(ALICE, { action = "select", slot = 4 }).info.selected, 4)
    t.ok(not handlers.act(ALICE, { action = "select" }), "select needs a slot")
    t.ok(not handlers.act(ALICE, { action = "select", slot = 17 }), "slot out of range")
    t.ok(not handlers.act(ALICE, { action = "getFuelLevel" }), "only listed actions run")
    t.ok(not handlers.act(ALICE, { action = "shutdown" }))
    t.eq(turtle_api.selected, 4)
  end)
end
