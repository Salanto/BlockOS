-- Remote admin: the manage handlers and remote shell sessions.
return function(t)
  local USERS = {
    ["root-token"] = { name = "root", groups = { "domain-users", "domain-admins" } },
    ["bob-token"] = { name = "bob", groups = { "domain-users" } },
  }
  local ROOT = { sender = 5, token = "root-token" }
  local BOB = { sender = 6, token = "bob-token" }

  local function new_manage()
    local import = t.fresh_import()
    import("rpc").set_user_validator(function(token) return USERS[token] end)
    local manage = import("manage")
    local queued, states = {}, { net = "running", ["computer-config"] = "failed" }
    manage.env = {
      services = function()
        return {
          list = function()
            return {
              { name = "net", state = states.net },
              { name = "computer-config", state = states["computer-config"], last_error = "boom" },
            }
          end,
          restart = function(name) states[name] = "running" return true end,
          start = function(name) states[name] = "running" return true end,
          stop = function(name) states[name] = "stopped" return true end,
          state = function(name) return states[name] end,
        }
      end,
      queue = function(event) queued[#queued + 1] = event end,
      log_tail = function(count) return { "line 1", "line " .. count } end,
      disk = function() return { free = 500000, capacity = 1000000 } end,
      installed = function() return { core = { version = "0.5.0" } } end,
      reboot = function() end,
    }
    return manage, queued, states, import
  end

  t.it("only domain admins may manage a computer", function()
    local manage = new_manage()
    local handlers = manage.handlers()
    t.ok(not handlers.status(BOB, {}), "bob is no domain admin")
    t.ok(not handlers.reboot({ sender = 7 }, {}), "no login")
    local status = handlers.status(ROOT, {})
    t.eq(status.failed, 1)
    t.eq(status.packages.core, "0.5.0")
  end)

  t.it("reboot and update are queued; services are controlled", function()
    local manage, queued, states = new_manage()
    local handlers = manage.handlers()
    t.ok(handlers.reboot(ROOT, {}))
    t.ok(handlers.update(ROOT, {}))
    t.eq(queued[1], "blockos_manage_reboot")
    t.eq(queued[2], "blockos_update_now")
    t.eq(handlers.service(ROOT, { name = "computer-config", action = "restart" }).state, "running")
    t.eq(states["computer-config"], "running")
    t.ok(not handlers.service(ROOT, { name = "net", action = "explode" }), "unknown action")
    t.eq(#handlers.log(ROOT, { lines = 99 }), 2)
    t.eq(handlers.log(ROOT, { lines = 99 })[2], "line 40", "capped")
  end)

  -- A remote shell session around a tiny program instead of a real shell.
  local function new_server(import)
    local remote_shell = import("remote_shell")
    local sent = {}
    remote_shell.env.send = function(id, message)
      sent[#sent + 1] = { id = id, message = message }
    end
    remote_shell.env.parent = function() return term.current() end
    local server = remote_shell.server(function()
      term.write("hello")
      local _, char = os.pullEvent("char")
      term.write(char)
      os.pullEvent("char")
    end)
    return server, sent, remote_shell
  end

  local function last_event(sent)
    local wire = t.fresh_import()("wire")
    local message = sent[#sent].message
    return wire.parse(message, "event", {}) or message
  end

  t.it("a remote shell shows the program's screen to the viewer and takes its keys", function()
    local manage, _, _, import = new_manage()
    local server, sent, remote_shell = new_server(import)
    local handlers = manage.handlers(server)
    t.ok(not handlers.shell_open(BOB, { width = 30, height = 10 }), "admins only")
    local opened = assert(handlers.shell_open(ROOT, { width = 30, height = 10 }))
    local function input(char)
      return remote_shell.input(opened.session, "char", char)
    end
    t.eq(sent[1].id, 5, "frames go to the computer that asked")
    local frame = last_event(sent)
    t.eq(frame.topic, "frame")
    t.ok(frame.data.lines[1][2]:find("^hello"), frame.data.lines[1][2])

    server.handle("char", "x") -- the computer's own keyboard: ignored
    t.eq(#sent, 1)
    server.handle("rednet_message", 9, input("x"), remote_shell.PROTOCOL)
    t.eq(#sent, 1, "input from another computer is ignored")
    server.handle("rednet_message", 5, input("x"), remote_shell.PROTOCOL)
    t.ok(last_event(sent).data.lines[1][2]:find("^hellox"), "the viewer's key reached the program")

    server.handle("rednet_message", 5, input("y"), remote_shell.PROTOCOL)
    t.eq(last_event(sent).topic, "closed", "the program ended, so the session closed")
    t.eq(server.count(), 0)
  end)
end
