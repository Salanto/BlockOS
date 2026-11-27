-- player-locator service: answers where players are (protocol "blockos.players"), from an
-- Advanced Peripherals Player Detector next to this computer or on its wired network.
-- Without a detector it waits, with a notice, and starts once one is attached.

local RECHECK_SECONDS = 30

local function find_detector()
  return peripheral.find("playerDetector")
end

local function wait_for_detector(ctx)
  local notices = import("notices")
  if find_detector() then
    return
  end
  ctx.log.warn("no Player Detector attached")
  notices.set("player_locator", "The player locator needs a Player Detector next to it")
  while not find_detector() do
    local timer = os.startTimer(RECHECK_SECONDS)
    repeat
      local event, value = os.pullEvent()
    until event == "peripheral" or (event == "timer" and value == timer)
  end
  notices.clear("player_locator")
end

local function run(ctx)
  local rpc = import("rpc")
  local players = import("players")
  wait_for_detector(ctx)
  local ok, err = import("discovery").advertise(players.SERVICE_TYPE, players.PROTOCOL)
  if not ok then
    ctx.log.warn("could not register the players service record: %s", tostring(err))
  end
  rpc.serve(players.PROTOCOL, import("player_locator").handlers(find_detector))
end

return {
  name = "player-locator",
  description = "Says where players are (Player Detector)",
  after = { "net", "domain-client" },
  restart = "on-failure",
  run = run,
}
