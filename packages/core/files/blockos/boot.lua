-- BlockOS kernel entry point.
--
-- Started by the loader as boot(root, env), where env is the environment of the
-- rom shell that ran /startup.lua (it holds `shell` and `multishell`).
--
-- Why `import` and not `require`: each CraftOS program gets its own `require`,
-- which only searches next to that program and the rom. BlockOS modules live in
-- <root>/kernel and <root>/lib, so the kernel provides `import` as a global.

local root, env = ...
root = root or "/blockos"
env = env or _ENV

local MODULE_DIRS = { "kernel", "lib" }

local loaded_modules = {}

--- Load <root>/kernel/<name>.lua or <root>/lib/<name>.lua once and cache it.
local function import(name)
  if loaded_modules[name] ~= nil then
    return loaded_modules[name]
  end
  for _, dir in ipairs(MODULE_DIRS) do
    local path = fs.combine(root, dir .. "/" .. name .. ".lua")
    if fs.exists(path) then
      local module_env = setmetatable({ import = import }, { __index = _G })
      local chunk, err = loadfile(path, nil, module_env)
      if not chunk then
        error(err, 0)
      end
      loaded_modules[name] = chunk()
      return loaded_modules[name]
    end
  end
  error("module not found: " .. name, 2)
end

local function add_bin_to_path(shell)
  local bin = "/" .. fs.combine(root, "bin")
  local path = shell.path()
  local already_there = (":" .. path .. ":"):find(":" .. bin .. ":", 1, true)
  if not already_there then
    -- Prepend, never replace: the rom adds device-specific program folders.
    shell.setPath(bin .. ":" .. path)
  end
end

_G.import = import
math.randomseed(os.epoch("utc") + os.getComputerID() * 7919)

local config = import("config")
local fsx = import("fsx")
local log = import("log")
local paths = import("paths")
local pkg = import("pkg")

log.level = config.get("blockos.log.level", "info")

--- The public BlockOS API, available to every program as `blockos`.
_G.blockos = {
  root = root,
  version = pkg.installed_version(root) or "dev",
  import = import,
  log = log,
  config = config,
  device = import("device"),
  ui = import("ui"),
  auth = import("auth"),
  pkg = pkg,
  services = import("services"),
  user = nil,
  net = nil, -- set by the net service when installed
}

--- End the current session and return to the login screen.
function blockos.logout()
  os.queueEvent(import("session").LOGOUT_EVENT)
end

log.info("kernel", "BlockOS %s booting from %s on a %s %s", blockos.version, root,
  blockos.device.is_advanced() and "advanced" or "basic", blockos.device.kind())

add_bin_to_path(env.shell)
if env.multishell then
  env.multishell.setTitle(env.multishell.getCurrent(), "BlockOS")
end

local scheduler = import("scheduler").new()
blockos.services.init(scheduler)
blockos.services.load(fs.combine(root, "services"))
blockos.services.start_all()

local function on_login_screen_ready()
  fsx.write(paths.bootcount(), "0")
  log.info("kernel", "boot complete")
end

parallel.waitForAny(
  function() scheduler:run() end,
  function() import("session").run(env.shell, on_login_screen_ready) end
)
error("kernel stopped", 0)
