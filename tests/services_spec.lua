-- Scheduler event delivery and the service manager's lifecycle rules.
return function(t)
  local function new_manager()
    local import = t.fresh_import()
    local scheduler = import("scheduler").new()
    local services = import("services")
    services.init(scheduler)
    return scheduler, services
  end

  local function event(...)
    return table.pack(...)
  end

  t.it("tasks only receive events matching their filter", function()
    local scheduler = t.fresh_import()("scheduler").new()
    local seen = {}
    scheduler:spawn("waiter", function()
      while true do
        local _, value = os.pullEvent("wanted")
        seen[#seen + 1] = value
      end
    end)
    scheduler:dispatch(event("other", 1))
    scheduler:dispatch(event("wanted", 2))
    t.eq(#seen, 1)
    t.eq(seen[1], 2)
  end)

  t.it("terminate is never delivered", function()
    local scheduler = t.fresh_import()("scheduler").new()
    local got_terminate = false
    scheduler:spawn("raw", function()
      while true do
        if os.pullEventRaw() == "terminate" then
          got_terminate = true
        end
      end
    end)
    scheduler:dispatch(event("terminate"))
    t.ok(not got_terminate)
  end)

  t.it("a crashing task reports its error and leaves the others running", function()
    local scheduler = t.fresh_import()("scheduler").new()
    local exit_error = nil
    scheduler:spawn("crasher", function()
      os.pullEvent("go")
      error("boom", 0)
    end, function(_, err) exit_error = err end)
    scheduler:spawn("survivor", function()
      while true do
        os.pullEvent()
      end
    end)
    scheduler:dispatch(event("go"))
    t.eq(exit_error, "boom")
    t.ok(not scheduler:is_running("crasher"))
    t.ok(scheduler:is_running("survivor"))
  end)

  t.it("services start in dependency order", function()
    local _, services = new_manager()
    local started = {}
    local function service(name, after)
      services.register({
        name = name,
        after = after,
        run = function()
          started[#started + 1] = name
          os.pullEvent("never")
        end,
      })
    end
    service("c", { "b" })
    service("a")
    service("b", { "a", "missing" })
    services.start_all()
    t.eq(table.concat(started, ","), "a,b,c")
  end)

  t.it("a service crashing 5 times in a row is marked failed", function()
    local _, services = new_manager()
    services.register({
      name = "flaky",
      run = function() error("always broken", 0) end,
    })
    services.start("flaky")
    -- Each crash schedules a restart; restart by hand instead of waiting for it.
    for _ = 1, 10 do
      if services.state("flaky") ~= "restarting" then
        break
      end
      services.start("flaky")
    end
    t.eq(services.state("flaky"), "failed")
    local entry = services.list()[1]
    t.eq(entry.last_error, "always broken")
  end)

  t.it("services whose condition is false are n/a, not failed", function()
    local _, services = new_manager()
    services.register({
      name = "turtle-only",
      condition = function() return false end,
      run = function() end,
    })
    services.start_all()
    t.eq(services.state("turtle-only"), "n/a")
  end)

  t.it("disabled services do not start", function()
    local import = t.fresh_import()
    local scheduler = import("scheduler").new()
    local services = import("services")
    local config = import("config")
    services.init(scheduler)
    local previous = settings.get("blockos.services.disabled")
    settings.set("blockos.services.disabled", { "quiet" })
    services.register({ name = "quiet", run = function() os.pullEvent("never") end })
    services.start_all()
    if previous == nil then
      settings.unset("blockos.services.disabled")
    else
      settings.set("blockos.services.disabled", previous)
    end
    t.eq(services.state("quiet"), "disabled")
    t.ok(config ~= nil)
  end)

  t.it("print inside a service goes to the log, not the screen", function()
    local import = t.fresh_import()
    local scheduler = import("scheduler").new()
    local services = import("services")
    local paths = import("paths")
    services.init(scheduler)
    t.write(t.sandbox .. "/services/chatty.lua",
      "return { run = function() print('hello from a service') os.pullEvent('never') end }")
    services.load(t.sandbox .. "/services")
    services.start_all()
    local log_text = t.read(paths.log()) or ""
    t.ok(log_text:find("hello from a service", 1, true), "print was not logged")
  end)

  t.it("services provide objects that are withdrawn when they stop", function()
    local services = t.fresh_import()("services")
    t.eq(services.get("thing"), nil)
    local thing = { name = "thing" }
    services.provide("thing", thing, "maker")
    t.eq(services.get("thing"), thing)
    local other = {}
    services.withdraw("thing", other)
    t.eq(services.get("thing"), thing, "only the one provided is withdrawn")
    services.withdraw("thing", thing)
    t.eq(services.get("thing"), nil)
    t.eq(services.await("thing", 0.1), nil, "await gives up after its timeout")
  end)
end
