-- BlockOS disk installer and recovery menu.
--
-- Becomes startup.lua on the install floppy. CraftOS runs a disk's startup
-- instead of the computer's own /startup.lua, which makes this disk the escape
-- hatch when an installation is broken.
--
-- Non-interactive use (tests, automation):
--   startup --action install|upgrade|boot|safe|rollback
--           [--admin <name> <password>] [--dir <disk dir>] [--prefix <sandbox>]

local BOOT_MENU_TIMEOUT = 5
local INSTALL_MENU_TIMEOUT = 30

local function parse_args(args)
  local options = {}
  local i = 1
  while i <= #args do
    local flag = args[i]
    if flag == "--action" then
      options.action = args[i + 1]
      i = i + 1
    elseif flag == "--admin" then
      options.admin = { name = args[i + 1], password = args[i + 2] }
      i = i + 2
    elseif flag == "--dir" then
      options.dir = args[i + 1]
      i = i + 1
    elseif flag == "--prefix" then
      options.prefix = args[i + 1]
      i = i + 1
    end
    i = i + 1
  end
  return options
end

local function read_file(path)
  local handle = fs.exists(path) and fs.open(path, "rb")
  if not handle then
    return nil
  end
  local data = handle.readAll()
  handle.close()
  return data
end

-- Load kernel modules straight out of the core package on the disk. The same
-- bootstrap exists in installer/install.lua: nothing is installed yet to share.
local function make_import(core)
  local loaded = {}
  local function import(name)
    if loaded[name] then
      return loaded[name]
    end
    local source = core.files["blockos/kernel/" .. name .. ".lua"]
    if not source then
      error("module not found: " .. name, 2)
    end
    local env = setmetatable({ import = import }, { __index = _G })
    loaded[name] = assert(load(source, "@" .. name, "t", env))()
    return loaded[name]
  end
  return import
end

local options = parse_args({ ... })
local disk_dir = options.dir or ("/" .. fs.getDir(shell.getRunningProgram()))

local core = textutils.unserialise(read_file(fs.combine(disk_dir, "packages/core.pkg")) or "")
if type(core) ~= "table" or type(core.files) ~= "table" then
  printError("This disk has no readable BlockOS core package.")
  return
end

local import = make_import(core)
local paths = import("paths")
paths.prefix = options.prefix or ""

local auth = import("auth")
local device = import("device")
local pkg = import("pkg")
local setup = import("setup")
local ui = import("ui")

local index = textutils.unserialise(read_file(fs.combine(disk_dir, "index.lua")) or "") or {}
local disk_version = tostring(index.version or core.manifest.version)
local installed_version = pkg.installed_version()
local is_interactive = options.action == nil

local function say(message, role)
  if is_interactive then
    ui.print(message, role)
  else
    print(message)
  end
end

local function finish(message)
  say(message, "ok")
  if is_interactive then
    ui.print("Remove the disk, then press any key to reboot.", "dim")
    ui.wait_for_key()
    os.reboot()
  end
end

local function fail(message)
  say("Error: " .. tostring(message), "error")
  return false
end

local function ensure_admin_account()
  if auth.has_users() then
    return true
  end
  if not options.admin then
    setup.create_admin()
    return true
  end
  return auth.add_user(options.admin.name, options.admin.password, true)
end

local function install()
  ui.clear()
  local verb = pkg.is_installed() and "Upgrading to" or "Installing"
  say(verb .. " BlockOS " .. disk_version, "title")

  local fetched, packages = pkg.fetch(pkg.disk_source(disk_dir), function(message)
    say(message, "dim")
  end)
  if not fetched then
    return fail(packages)
  end
  local ok, err = pkg.apply(packages, { progress = function(message) say(message, "dim") end })
  if not ok then
    return fail(err)
  end
  if not pkg.has_loader() then
    local note = pkg.install_loader(core.files["blockos/loader.lua"])
    if note then
      say(note, "warn")
    end
  end
  ok, err = ensure_admin_account()
  if not ok then
    return fail(err)
  end
  finish("BlockOS " .. disk_version .. " is installed.")
  return true
end

local function roll_back()
  local ok, err = pkg.rollback()
  if not ok then
    return fail(err)
  end
  finish("Rolled back to the previous version.")
  return true
end

local function safe_mode()
  ui.clear()
  say("Safe mode: BlockOS was not started.", "warn")
  say("Type 'reboot' to restart. Remove the disk to boot BlockOS normally.", "dim")
  return true
end

local function boot_installed()
  ui.clear()
  shell.run(paths.startup())
  return true
end

local ACTIONS = {
  install = install,
  upgrade = install,
  rollback = roll_back,
  safe = safe_mode,
  boot = boot_installed,
}

local function show_install_menu()
  local choice = ui.menu({
    title = "BlockOS " .. disk_version .. " installer",
    text = "BlockOS is not installed on this " .. device.kind() .. ".",
    items = { "Install BlockOS", "Exit to CraftOS" },
    default = 2,
    timeout = INSTALL_MENU_TIMEOUT,
  })
  if choice == 1 then
    install()
  else
    ui.clear()
  end
end

-- Booting is the default, so a disk left in the drive never blocks startup.
local function show_recovery_menu()
  local order = pkg.compare_versions(disk_version, installed_version or "0")
  local install_label = "Reinstall " .. disk_version
  if order > 0 then
    install_label = "Upgrade to " .. disk_version
  elseif order < 0 then
    install_label = "Downgrade to " .. disk_version
  end

  local entries = {
    { label = "Boot BlockOS " .. tostring(installed_version), run = boot_installed },
    { label = install_label, run = install },
    { label = "Safe mode (CraftOS shell)", run = safe_mode },
  }
  if fs.exists(fs.combine(paths.previous(), "boot.lua")) then
    entries[#entries + 1] = { label = "Roll back to the previous version", run = roll_back }
  end

  local labels = {}
  for i, entry in ipairs(entries) do
    labels[i] = entry.label
  end
  local choice = ui.menu({
    title = "BlockOS install disk",
    text = "Installed: " .. tostring(installed_version) .. "   On disk: " .. disk_version,
    items = labels,
    default = 1,
    timeout = BOOT_MENU_TIMEOUT,
  })
  entries[choice].run()
end

-- Non-interactive: raise on failure so shell.run reports it to the caller.
if options.action then
  local action = ACTIONS[options.action]
  if not action then
    error("unknown action: " .. options.action, 0)
  end
  if not action() then
    error(options.action .. " failed", 0)
  end
  return
end

if pkg.is_installed() then
  show_recovery_menu()
else
  show_install_menu()
end
