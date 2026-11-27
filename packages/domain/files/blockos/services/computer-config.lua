-- computer-config service: applies this computer's computer roles from the directory
-- (settings, packages to install) and keeps its packages up to date.
--
-- Checks shortly after boot, every blockos.domain.update_interval seconds, and right away
-- on the event "blockos_update_now" (sent by remote admin from dsa). Changes are applied
-- when nobody is logged in; when someone is, a notice says an update is ready and it is
-- applied after they log out. A forced update applies at once.

local UPDATE_NOW_EVENT = import("computer_config").UPDATE_NOW_EVENT
local FIRST_CHECK_SECONDS = 20
local PENDING_POLL_SECONDS = 10

local function run(ctx)
  local domain = import("domain")
  if not domain.is_joined() then
    ctx.log.info("not in a domain: computer roles are off")
    return
  end
  local computer_config = import("computer_config")
  local pkg = import("pkg")
  local log = ctx.log
  local pending = nil -- fetched packages waiting for nobody to be logged in

  local function apply(result)
    log.info("applying: %s", computer_config.describe(result.changes))
    local function progress(text)
      log.info("%s", text)
    end
    local ok, err = pkg.apply(result.packages, { progress = progress })
    if not ok then
      log.error("update failed: %s", tostring(err))
      pending = nil
      if blockos.notices then
        blockos.notices.update = nil
      end
      return
    end
    log.info("update applied, rebooting")
    sleep(1)
    os.reboot()
  end

  local function check(is_forced)
    local result, err = computer_config.check()
    if not result then
      log.warn("%s", tostring(err))
      return
    end
    if #result.settings_changed > 0 then
      log.info("settings from computer roles: %s", table.concat(result.settings_changed, ", "))
    end
    if #result.missing > 0 then
      log.warn("not found on the package source: %s", table.concat(result.missing, ", "))
    end
    if not result.packages then
      return
    end
    local is_auto = ctx.config.get("blockos.domain.auto_update", true)
    if not is_forced and not is_auto then
      log.info("updates available but automatic updates are off: %s",
        computer_config.describe(result.changes))
      return
    end
    if is_forced or not blockos.user then
      apply(result)
      return
    end
    pending = result
    if blockos.notices then
      blockos.notices.update = #result.changes ..
        " package update(s) ready: applied when you log out"
    end
  end

  local timer = os.startTimer(FIRST_CHECK_SECONDS)
  local poll = nil
  while true do
    local event, id = os.pullEvent()
    if event == "timer" and id == timer then
      check(false)
      timer = os.startTimer(ctx.config.get("blockos.domain.update_interval", 1800))
      if pending and not poll then
        poll = os.startTimer(PENDING_POLL_SECONDS)
      end
    elseif event == "timer" and id == poll then
      poll = nil
      if pending and not blockos.user then
        apply(pending)
      elseif pending then
        poll = os.startTimer(PENDING_POLL_SECONDS)
      end
    elseif event == UPDATE_NOW_EVENT then
      check(true)
    end
  end
end

return {
  name = "computer-config",
  description = "Applies this computer's roles and keeps its packages up to date",
  after = { "net", "domain-client" },
  restart = "on-failure",
  run = run,
}
