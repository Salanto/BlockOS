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

local LOGO_MIN_HEIGHT = 17
local LOGIN_HINTS = { { "Enter", "Next" } }

-- Draws the login screen and returns where the two input fields go.
local function draw_login_screen(message)
  local width, height = ui.size()
  local version = blockos and blockos.version or ""
  local hint = auth.login_hint()
  ui.clear()
  ui.header(1, "BlockOS " .. version, describe_device())

  local panel_top = nil
  if height >= LOGO_MIN_HEIGHT then
    ui.logo(math.floor((width - 6) / 2) + 1, 3)
    panel_top = 7
  end
  local panel_height = 6 + (hint and 2 or 0)
  local x, y, field_width = ui.panel(panel_height, "Sign in", panel_top)
  if hint then
    ui.text_at(x, y, ui.fit(hint, field_width), "dim", "panel")
    y = y + 2
  end
  if message then
    ui.text_at(x, y + 3, ui.fit(message, field_width), "error", "panel")
  end
  local motd = settings.get("blockos.motd")
  if motd and motd ~= "" then
    ui.center(height - 1, ui.fit(motd, width), "title")
  end
  ui.footer(LOGIN_HINTS)
  return { x = x, y = y, width = field_width }
end

-- Returns the user record, or false and a message; raises on Ctrl+T.
local function ask_credentials(fields)
  local name = ui.field_prompt(fields.x, fields.y, fields.width, "Username ")
  local password = ui.field_prompt(fields.x, fields.y + 1, fields.width, "Password ",
    { mask = "*" })
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
    local fields = draw_login_screen(message)
    ready()
    local ok, result, err = pcall(ask_credentials, fields)
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
  ui.use("title")
  write("Welcome, " .. user.name .. ". ")
  ui.print("Type 'logout' to log out.", "dim")
  for _, notice in pairs(blockos and blockos.notices or {}) do
    ui.status(notice, "warn")
  end

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

--- The user to log in automatically at boot, if the blockos.autologin setting
-- names an existing local account (for farm computers, displays and turtles).
-- @treturn table|nil A user record.
function session.autologin_user()
  local name = settings.get("blockos.autologin")
  local account = name and name ~= "" and auth.get(name)
  if not account then
    return nil
  end
  return { name = account.name, source = "local", groups = {}, is_admin = account.is_admin }
end

--- Login/session loop. Never returns.
-- @tparam table shell The rom shell API.
-- @tparam[opt] function on_ready Called once the first login screen is up.
function session.run(shell, on_ready)
  local user_shell = session.default_shell(shell)
  -- Only at boot: after a logout, the login screen is shown as usual.
  local user = session.autologin_user()
  if user then
    log.info("session", "%s logged in automatically", user.name)
    if on_ready then
      on_ready()
      on_ready = nil
    end
    session.run_user(user, user_shell)
  end
  while true do
    user = session.login(on_ready)
    on_ready = nil
    session.run_user(user, user_shell)
  end
end

return session
