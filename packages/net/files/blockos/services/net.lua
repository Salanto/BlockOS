-- net service: opens modems, registers the hostname with rednet and, without a
-- domain, keeps the peer table fresh with announces (joined computers report to
-- the domain controller instead). Modems can come and go at any time (turtles
-- swap upgrades), so being offline is a normal state, not an error.

local function is_modem(side)
  return peripheral.getType(side) == "modem"
end

local function any_modem_open()
  for _, side in ipairs(peripheral.getNames()) do
    if is_modem(side) and rednet.isOpen(side) then
      return true
    end
  end
  return false
end

-- Every modem except closed ones (see net.close_side: a storage network's modem).
local function open_all_modems(net)
  for _, side in ipairs(peripheral.getNames()) do
    if is_modem(side) and not net.is_closed_side(side) then
      rednet.open(side)
    elseif is_modem(side) and rednet.isOpen(side) then
      rednet.close(side)
    end
  end
end

local function run(ctx)
  local net = import("net")
  local log = ctx.log
  local registered_name = nil
  blockos.net = net

  local function try_host(name)
    return pcall(rednet.host, net.HOST_PROTOCOL, name)
  end

  -- rednet.host refuses names already hosted by another computer it can reach.
  local function register(wanted)
    if not net.is_online() then
      net.set_current_hostname(wanted)
      return
    end
    if registered_name then
      rednet.unhost(net.HOST_PROTOCOL)
      registered_name = nil
    end

    local name = wanted
    local ok, err = try_host(name)
    if not ok and tostring(err):find("in use") then
      name = net.sanitize(wanted .. "-" .. os.getComputerID())
      log.warn("hostname %s is in use; using %s", wanted, name)
      ok, err = try_host(name)
    end
    if ok then
      registered_name = name
    else
      log.error("could not register hostname %s: %s", name, tostring(err))
    end

    net.set_current_hostname(name)
    if os.getComputerLabel() ~= name then
      os.setComputerLabel(name)
    end
    log.info("hostname is %s", name)
  end

  -- Joined computers report to the domain controller instead of broadcasting.
  local function announce(is_hello)
    if net.directory() then
      return
    end
    if net.is_online() and net.hostname() then
      rednet.broadcast(net.build_announce(is_hello), net.ANNOUNCE_PROTOCOL)
    end
  end

  local function update_online_state()
    local was_online = net.is_online()
    net.set_online(any_modem_open())
    if net.is_online() and not was_online then
      log.info("online")
      register(net.hostname() or net.default_hostname())
      announce(true)
    elseif was_online and not net.is_online() then
      log.info("offline (no modem)")
      registered_name = nil
    end
  end

  local function on_announce(sender, message)
    if sender == os.getComputerID() then
      return
    end
    local payload = net.handle_announce(sender, message)
    -- A newcomer says hello: answer directly so it learns about us right away.
    if payload and payload.hello and net.is_online() and not net.directory() then
      rednet.send(sender, net.build_announce(), net.ANNOUNCE_PROTOCOL)
    end
  end

  open_all_modems(net)
  net.set_current_hostname(net.default_hostname())
  update_online_state()
  if not net.is_online() then
    log.info("offline (no modem)")
  end

  local interval = ctx.config.get("blockos.net.announce_interval", 30)
  local announce_timer = os.startTimer(interval)
  while true do
    local event, a, b, c = os.pullEvent()
    if event == "rednet_message" and c == net.ANNOUNCE_PROTOCOL then
      on_announce(a, b)
    elseif event == "timer" and a == announce_timer then
      net.prune()
      announce(false)
      announce_timer = os.startTimer(interval)
    elseif event == "peripheral" and is_modem(a) and not net.is_closed_side(a) then
      rednet.open(a)
      update_online_state()
    elseif event == "peripheral_detach" then
      update_online_state()
    elseif event == net.RENAME_EVENT then
      register(a)
      announce(false)
    end
  end
end

return {
  name = "net",
  description = "Modems, hostname and peer discovery",
  restart = "on-failure",
  run = run,
}
