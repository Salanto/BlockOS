--- The interactive session: login screen, the user's shell, back to login.
--
-- There is one code path for every device. On advanced devices the user gets a
-- nested multishell, so every tab they open belongs to the session and is
-- closed on logout. Basic devices get a plain shell.
-- @module session

local auth = import("auth")
local device = import("device")
local log = import("log")
local setup = import("setup")
local ui = import("ui")

local session = {}

--- Queue this event to end the current session.
session.LOGOUT_EVENT = "blockos_logout"

local SHELL_PROGRAM = "/rom/programs/shell.lua"
local MULTISHELL_PROGRAM = "/rom/programs/advanced/multishell.lua"

local function describe_device()
  local id = "#" .. os.getComputerID()
  local label = os.getComputerLabel()
  if label then
    return label .. " (" .. id .. ")"
  end
  return "Computer " .. id
end

local function draw_login_screen(message)
  local _, height = ui.size()
  local version = blockos and blockos.version or ""
  ui.clear()
  ui.bar(1, "BlockOS " .. version)
  ui.line(3, describe_device(), "dim")
  local hint = auth.login_hint()
  if hint then
    ui.line(4, hint, "dim")
  end
  if message then
    ui.line(height, message, "error")
  end
  term.setCursorPos(1, 6)
end

-- Returns the user record, or false and a message; raises on Ctrl+T.
local function ask_credentials()
  local name = ui.prompt("Username: ")
  local password = ui.prompt("Password: ", { mask = "*" })
  local user, err = auth.login(name, password)
  if not user then
    return false, err
  end
  return user
end

--- Show the login screen until valid credentials are entered.
--
-- Runs first-boot setup if there are no local accounts. Ctrl+T restarts the
-- prompt instead of escaping.
-- @tparam[opt] function on_ready Called once the screen is up.
-- @treturn table The user record { name, source, groups, is_admin, token? }.
function session.login(on_ready)
  local function ready()
    if on_ready then
      on_ready()
      on_ready = nil
    end
  end

  if not auth.has_users() then
    log.warn("session", "no user accounts found; running first-boot setup")
    ready()
    setup.create_admin()
  end

  local message = nil
  while true do
    draw_login_screen(message)
    ready()
    local ok, result, err = pcall(ask_credentials)
    if ok and result then
      log.info("session", "%s logged in (%s)", result.name, result.source or "local")
      return result
    elseif ok then
      message = err or "Login incorrect."
      log.info("session", "failed login: %s", tostring(message))
    elseif result ~= "Terminated" then
      error(result, 0)
    end
  end
end

--- The default user shell for this device.
-- @tparam table shell The rom shell API.
-- @treturn function Runs the shell until it exits.
function session.default_shell(shell)
  return function()
    -- Decided by the device type only: the rom's own multishell can be turned
    -- off in settings, but the program is always there on advanced devices.
    if device.is_advanced() then
      shell.run(MULTISHELL_PROGRAM)
    else
      shell.run(SHELL_PROGRAM)
    end
  end
end

local function wait_for_logout()
  while true do
    local event = os.pullEventRaw()
    if event == session.LOGOUT_EVENT then
      return
    end
  end
end

--- Run a user's session until their shell exits or a logout event arrives.
-- @tparam table user
-- @tparam function user_shell
function session.run_user(user, user_shell)
  local terminal_before = term.current()
  if blockos then
    blockos.user = user
  end
  ui.clear()
  ui.print("Welcome, " .. user.name .. ". Type 'logout' to log out.", "dim")

  parallel.waitForAny(user_shell, wait_for_logout)

  -- Every coroutine of the session (shell, tabs, programs) has now been dropped.
  term.redirect(terminal_before)
  auth.logout(user)
  if blockos then
    blockos.user = nil
  end
  ui.clear()
  log.info("session", "%s logged out", user.name)
end

--- Login/session loop. Never returns.
-- @tparam table shell The rom shell API.
-- @tparam[opt] function on_ready Called once the first login screen is up.
function session.run(shell, on_ready)
  local user_shell = session.default_shell(shell)
  while true do
    local user = session.login(on_ready)
    on_ready = nil
    session.run_user(user, user_shell)
  end
end

return session
