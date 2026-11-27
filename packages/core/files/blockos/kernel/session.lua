--- The interactive session: login screen, the user's shell, back to login.
--
-- There is one code path for every device. On advanced devices the user gets a
-- nested multishell, so every tab they open belongs to the session and is
-- closed on logout. Basic devices get a plain shell.
--
-- Login hooks (session.set_login_hook) add to a user's session: the domain package
-- fetches the user's roaming profile, whose apps open in tabs (advanced devices) or
-- are listed on the welcome screen (basic ones), and whose settings apply until
-- logout.
-- @module session

local auth = import("auth")
local config = import("config")
local device = import("device")
local log = import("log")
local setup = import("setup")
local ui = import("ui")

local session = {}

--- Queue this event to end the current session.
session.LOGOUT_EVENT = "blockos_logout"
--- Queued once a session has ended and nobody is logged in (services waiting for an
-- empty computer, e.g. to apply updates, listen for it).
session.LOGGED_OUT_EVENT = "blockos_logged_out"
--- Queued (with a source and its data) when a service adds a notice, e.g. a stock
-- alert or a message, so a program on screen can react.
session.NOTICE_EVENT = "blockos_notice"

local SHELL_PROGRAM = "/rom/programs/shell.lua"
local MULTISHELL_PROGRAM = "/rom/programs/advanced/multishell.lua"
-- Opens the user's apps in tabs, then becomes the shell (see multishell_with_apps).
local APPS_PROGRAM = "bin/session-apps.lua"

local login_hooks = {} -- [name] = hook

--- Add something to every session: hook(user) -> { apps?, settings? } or nil.
-- Called after login; apps from all hooks are opened, settings apply until logout.
-- @tparam string name Setting it again replaces the hook (a restarted service).
-- @tparam[opt] function hook nil removes it
function session.set_login_hook(name, hook)
  login_hooks[name] = hook
end

--- What the login hooks add for a user (a failing hook is logged and skipped).
-- @tparam table user
-- @treturn table { apps = {...}, settings = {...} }
function session.profile_for(user)
  local profile = { apps = {}, settings = {} }
  local names = {}
  for name in pairs(login_hooks) do
    names[#names + 1] = name
  end
  table.sort(names)
  -- Hooks run side by side: each may ask a server (quickly), and login waits for the
  -- slowest, not for all of them added up.
  local results = {}
  local runners = {}
  for index, name in ipairs(names) do
    runners[index] = function()
      results[index] = table.pack(pcall(login_hooks[name], user))
    end
  end
  if #runners > 0 then
    parallel.waitForAll(table.unpack(runners))
  end
  for index in ipairs(names) do
    local ok, result = results[index][1], results[index][2]
    if not ok then
      log.warn("session", "login hook failed: %s", tostring(result))
    elseif type(result) == "table" then
      for _, app in ipairs(result.apps or {}) do
        profile.apps[#profile.apps + 1] = app
      end
      for key, value in pairs(result.settings or {}) do
        profile.settings[key] = value
      end
    end
  end
  return profile
end

--- The rom's multishell, changed so its first shell runs a command: it always starts
-- a plain shell, so this is the one way to open more tabs at the start.
-- @tparam string source multishell.lua
-- @treturn string|nil The changed source, or nil if the rom's file looks different.
function session.patch_multishell(source)
  -- Some roms (CraftOS-PC's) already hand their arguments to the first shell.
  if source:find("[\"']/?rom/programs/shell%.lua[\"']%s*,%s*%.%.%.%s*%)") then
    return source
  end
  local patched, count = source:gsub(
    "(launchProcess%(%s*true%s*,.-[\"']/?rom/programs/shell%.lua[\"'])%s*%)", "%1, ...)", 1)
  if count ~= 1 then
    return nil
  end
  return patched
end

-- Run multishell with the apps opened in tabs; false if that is not possible (the
-- caller then runs the plain multishell).
local function multishell_with_apps(shell, apps)
  local file = fs.open(MULTISHELL_PROGRAM, "r")
  if not file then
    return false
  end
  local source = session.patch_multishell(file.readAll())
  file.close()
  if not source then
    return false
  end
  local env = setmetatable({ shell = shell }, { __index = _G })
  env.require, env.package = dofile("/rom/modules/main/cc/require.lua").make(env,
    "/rom/programs/advanced")
  local program = load(source, "@" .. MULTISHELL_PROGRAM, "t", env)
  if not program then
    return false
  end
  local apps_program = fs.combine(import("paths").root(), APPS_PROGRAM)
  program("/" .. apps_program, table.unpack(apps))
  return true
end

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
-- @treturn function function(apps) runs the shell until it exits.
function session.default_shell(shell)
  return function(apps)
    -- Decided by the device type only: the rom's own multishell can be turned
    -- off in settings, but the program is always there on advanced devices.
    if device.is_advanced() then
      if not (apps and #apps > 0 and multishell_with_apps(shell, apps)) then
        shell.run(MULTISHELL_PROGRAM)
      end
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
  local profile = session.profile_for(user)
  config.set_session(profile.settings)
  ui.clear()
  ui.use("title")
  write("Welcome, " .. user.name .. ". ")
  ui.print("Type 'logout' to log out.", "dim")
  if #profile.apps > 0 and not device.is_advanced() then
    ui.print("Your apps: " .. table.concat(profile.apps, ", "), "dim")
  end
  for _, notice in pairs(blockos and blockos.notices or {}) do
    ui.status(notice, "warn")
  end

  parallel.waitForAny(function() user_shell(profile.apps) end, wait_for_logout)
  config.set_session(nil)

  -- Every coroutine of the session (shell, tabs, programs) has now been dropped.
  term.redirect(terminal_before)
  auth.logout(user)
  if blockos then
    blockos.user = nil
  end
  os.queueEvent(session.LOGGED_OUT_EVENT, user.name)
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
