-- Request/response calls over a loopback transport (client and server in one computer).
return function(t)
  local PROTOCOL = "test.rpc"
  local ME = os.getComputerID()

  -- Run `client` while a server with `handlers` answers on PROTOCOL.
  local function with_server(rpc, handlers, client)
    rpc.set_transport(rpc.loopback_transport())
    local result = nil
    parallel.waitForAny(
      function() rpc.serve(PROTOCOL, handlers) end,
      function() result = table.pack(client()) end
    )
    return table.unpack(result, 1, result.n)
  end

  t.it("a call gets the handler's result", function()
    local rpc = t.fresh_import()("rpc")
    local handlers = {
      add = function(_, args) return args.a + args.b end,
    }
    local result = with_server(rpc, handlers, function()
      return rpc.call(ME, PROTOCOL, "add", { a = 2, b = 3 })
    end)
    t.eq(result, 5)
  end)

  t.it("handler errors and unknown operations come back as errors", function()
    local rpc = t.fresh_import()("rpc")
    local handlers = {
      broken = function() error("kaboom", 0) end,
      refuse = function() return nil, "not today" end,
    }
    with_server(rpc, handlers, function()
      local ok, err = rpc.call(ME, PROTOCOL, "broken")
      t.eq(ok, nil)
      t.ok(err:find("kaboom"), err)
      local _, refuse_error = rpc.call(ME, PROTOCOL, "refuse")
      t.eq(refuse_error, "not today")
      local _, missing_error = rpc.call(ME, PROTOCOL, "missing")
      t.ok(missing_error:find("unknown operation"), missing_error)
    end)
  end)

  t.it("a call with no server times out after its retries", function()
    local rpc = t.fresh_import()("rpc")
    rpc.set_transport({ send = function() end })
    local started = os.clock()
    local result, err = rpc.call(ME, PROTOCOL, "anything", nil, { timeout = 0.2, retries = 1 })
    t.eq(result, nil)
    t.ok(err:find("no answer"), err)
    t.ok(os.clock() - started >= 0.35, "did not wait for both attempts")
  end)

  t.it("a slow handler does not block other requests", function()
    local rpc = t.fresh_import()("rpc")
    local handlers = {
      slow = function() sleep(0.5) return "slow" end,
      fast = function() return "fast" end,
    }
    with_server(rpc, handlers, function()
      local order = {}
      local function call(op)
        local result, err = rpc.call(ME, PROTOCOL, op)
        order[#order + 1] = result or ("error: " .. tostring(err))
      end
      parallel.waitForAll(
        function() call("slow") end,
        function()
          sleep(0.1)
          call("fast")
        end
      )
      t.eq(table.concat(order, ","), "fast,slow")
    end)
  end)

  t.it("requests and responses of another wire version are ignored", function()
    local rpc = t.fresh_import()("rpc")
    t.ok(rpc.is_request({ v = 1, kind = "request", id = "x", op = "y" }))
    t.ok(not rpc.is_request({ v = 2, kind = "request", id = "x", op = "y" }))
    t.ok(not rpc.is_request({ v = 1, kind = "response", reply_to = "x", ok = true }))
    t.ok(rpc.is_response({ v = 1, kind = "response", reply_to = "x", ok = true }))
    t.ok(not rpc.is_response({ v = 2, kind = "response", reply_to = "x", ok = true }))
  end)

  t.it("require_user needs a valid token and the right group", function()
    local rpc = t.fresh_import()("rpc")
    rpc.set_user_validator(function(token)
      if token == "good" then
        return { name = "alice", groups = { "domain-users", "engineers" } }
      end
      return nil
    end)
    t.eq(select(2, rpc.require_user({})), rpc.LOGIN_REQUIRED)
    t.eq(select(2, rpc.require_user({ token = "expired" })), rpc.LOGIN_REQUIRED)
    t.eq(rpc.require_user({ token = "good" }).name, "alice")
    t.ok(rpc.require_user({ token = "good" }, { "engineers" }))
    t.eq(select(2, rpc.require_user({ token = "good" }, { "admins" })), rpc.PERMISSION_DENIED)
  end)

  t.it("require_computer asks who a computer token belongs to", function()
    local rpc = t.fresh_import()("rpc")
    rpc.set_computer_validator(function(token)
      return token == "crafter-token" and { hostname = "crafter" } or nil
    end)
    t.eq(rpc.require_computer({ computer_token = "crafter-token" }).hostname, "crafter")
    t.ok(not rpc.require_computer({ computer_token = "other" }))
    t.ok(not rpc.require_computer({}))
  end)

  t.it("calls carry the logged-in user's token and the computer token", function()
    local rpc = t.fresh_import()("rpc")
    rpc.set_computer_token_provider(function() return "computer-1" end)
    _G.blockos = { user = { name = "bob", token = "user-1" } }
    local handlers = {
      whoami = function(ctx) return { token = ctx.token, computer = ctx.computer_token } end,
    }
    local result = with_server(rpc, handlers, function()
      return rpc.call(ME, PROTOCOL, "whoami")
    end)
    t.eq(result.token, "user-1")
    t.eq(result.computer, "computer-1")
  end)

  t.it("a retried request runs once: slow answers and repeats never double it", function()
    local rpc = t.fresh_import()("rpc")
    local runs = 0
    local handlers = {
      move = function()
        runs = runs + 1
        sleep(0.3) -- longer than the caller's timeout: the caller sends it again
        return runs
      end,
    }
    local result = with_server(rpc, handlers, function()
      return rpc.call(ME, PROTOCOL, "move", nil, { timeout = 0.2, retries = 2 })
    end)
    t.eq(result, 1, "the retry got the first run's answer")
    t.eq(runs, 1, "the handler ran once")
  end)

  t.it("events that arrive while a call waits are kept for the caller's loop", function()
    local import = t.fresh_import()
    local rpc = import("rpc")
    local events = import("events")
    local handlers = {
      slow = function()
        sleep(0.2)
        return true
      end,
    }
    with_server(rpc, handlers, function()
      local timer = os.startTimer(0.05) -- the caller's own timer fires mid-call
      os.queueEvent("my_alert", 7)
      t.ok(rpc.call(ME, PROTOCOL, "slow", nil, { timeout = 1 }))
      local name, value = events.pull("my_alert")
      t.eq(name, "my_alert")
      t.eq(value, 7, "the alert was not lost")
      -- Other timers (the server's sleep) are kept too; the caller's is among them.
      local found = false
      while events.count() > 0 and not found do
        local kind, fired = events.pull()
        found = kind == "timer" and fired == timer
      end
      t.ok(found, "the caller's timer was kept too")
    end)
  end)
end
