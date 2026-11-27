-- Logging in with a domain account while the domain controller is down.
return function(t)
  t.it("a controller that does not answer points to local accounts, quickly", function()
    local import = t.fresh_import()
    local rpc = import("rpc")
    local domain = import("domain")
    domain.set_membership({ name = "home", controller_id = 999, computer_token = "x" })
    local calls = {}
    rpc.call = function(id, protocol, op, _, options)
      calls[#calls + 1] = { id = id, protocol = protocol, op = op, options = options }
      return nil, "no answer from computer #" .. id
    end
    rpc.find = function()
      error("a login must not search the network for a moved controller")
    end
    local user, err = domain.login_provider().login("alice", "secret")
    t.eq(user, nil)
    t.ok(tostring(err):find("%.\\name"), tostring(err))
    t.eq(#calls, 1)
    t.ok(calls[1].options.is_quick, "login gives up quickly")
  end)
end
