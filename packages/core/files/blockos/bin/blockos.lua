-- blockos: inspect and control the running system.
local args = { ... }

local ui = blockos.ui
local services = blockos.services

local STATE_ROLES = {
  running = "ok",
  failed = "error",
  crashed = "error",
  restarting = "warn",
}

local function print_usage()
  print("Usage:")
  print("  blockos status")
  print("  blockos services")
  print("  blockos start|stop|restart <service>")
  print("  blockos log [lines]")
  print("  blockos rollback")
  print("  blockos cleanup")
  print("  blockos autologin <user> | off")
  print("  blockos motd <message...> | off")
  print("  blockos version")
end

local function is_admin()
  if blockos.user and blockos.user.is_admin then
    return true
  end
  ui.print("Only administrators can do that.", "error")
  return false
end

-- "12345" bytes -> "12.1KB"
local function format_bytes(bytes)
  if bytes >= 1024 * 1024 then
    return string.format("%.1fMB", bytes / (1024 * 1024))
  elseif bytes >= 1024 then
    return string.format("%.1fKB", bytes / 1024)
  end
  return bytes .. "B"
end

local function file_size(path)
  if fs.exists(path) then
    return fs.getSize(path)
  end
  return 0
end

-- Where this computer's disk space goes.
local function disk_usage()
  local fsx = blockos.import("fsx")
  local paths = blockos.import("paths")
  return {
    free = fs.getFreeSpace("/"),
    system = fsx.tree_size(paths.root()),
    previous = fsx.tree_size(paths.previous()),
    logs = file_size(paths.log()) + file_size(paths.log() .. ".1"),
  }
end

-- Free space: the previous version (no rollback afterwards) and the old log.
local function clean_up()
  if not is_admin() then
    return
  end
  local paths = blockos.import("paths")
  local usage = disk_usage()
  local rotated_log = paths.log() .. ".1"
  local freed = usage.previous + file_size(rotated_log)
  if freed == 0 then
    print("Nothing to clean up.")
    return
  end
  ui.print("This frees " .. format_bytes(freed) .. ":", "title")
  if usage.previous > 0 then
    print("  the previous version (" .. format_bytes(usage.previous) .. ");")
    print("  rollback will no longer be possible")
  end
  if fs.exists(rotated_log) then
    print("  the old log (" .. format_bytes(file_size(rotated_log)) .. ")")
  end
  write("Continue? [y/N] ")
  if read():lower() ~= "y" then
    return
  end
  if fs.exists(paths.previous()) then
    fs.delete(paths.previous())
  end
  if fs.exists(rotated_log) then
    fs.delete(rotated_log)
  end
  ui.print("Freed " .. format_bytes(freed) .. ".", "ok")
end

local function format_uptime(seconds)
  seconds = math.floor(seconds)
  if seconds >= 3600 then
    return string.format("%dh %dm", math.floor(seconds / 3600), math.floor(seconds % 3600 / 60))
  elseif seconds >= 60 then
    return string.format("%dm %ds", math.floor(seconds / 60), seconds % 60)
  end
  return seconds .. "s"
end

local function show_status()
  local device = blockos.device
  local hardware = device.is_advanced() and "advanced" or "basic"
  ui.title("BlockOS " .. blockos.version)
  ui.field("Device", hardware .. " " .. device.kind())
  ui.field("Computer", "#" .. os.getComputerID() .. " " .. (os.getComputerLabel() or ""))
  if blockos.net then
    local hostname = blockos.net.full_hostname and blockos.net.full_hostname()
    ui.field("Hostname", tostring(hostname or blockos.net.hostname()))
  end
  ui.field("User", blockos.user and blockos.user.name or "-")
  ui.field("Uptime", format_uptime(os.clock()))

  local counts = {}
  for _, service in ipairs(services.list()) do
    counts[service.state] = (counts[service.state] or 0) + 1
  end
  local parts = {}
  for state, count in pairs(counts) do
    parts[#parts + 1] = count .. " " .. state
  end
  table.sort(parts)
  local has_problems = (counts.failed or 0) + (counts.crashed or 0) > 0
  ui.field("Services", table.concat(parts, ", "), has_problems and "warn" or "ok")

  local usage = disk_usage()
  print()
  ui.title("Disk")
  ui.field("Free", format_bytes(usage.free), usage.free < 64 * 1024 and "warn" or "ok")
  ui.field("System", format_bytes(usage.system))
  ui.field("Previous", format_bytes(usage.previous))
  ui.field("Logs", format_bytes(usage.logs))
end

local function show_services()
  for _, service in ipairs(services.list()) do
    ui.use("text")
    write(ui.pad(service.name, 16))
    ui.status(service.state, STATE_ROLES[service.state] or "faint")
    if service.last_error and service.state ~= "running" then
      ui.print("  " .. service.last_error, "dim")
    end
  end
end

local function control_service(action, name)
  if not name then
    print_usage()
    return
  end
  if not is_admin() then
    return
  end
  local ok, err = services[action](name)
  if ok then
    ui.print(action .. " " .. name .. ": ok", "ok")
  else
    ui.print(action .. " " .. name .. ": " .. tostring(err), "error")
  end
end

local LOG_LEVEL_ROLES = { ERROR = "error", CRASH = "error", WARN = "warn", DEBUG = "faint" }

-- Log lines look like "2026-01-01 12:00:00 [WARN] net: offline"; the time is
-- dimmed and the rest coloured by level.
local function show_log(count)
  for _, line in ipairs(blockos.log.tail(tonumber(count) or 15)) do
    local time, level, rest = line:match("^%S+ (%S+) %[(%u+)%] (.*)$")
    if time then
      ui.use("faint")
      write(time .. " ")
      ui.print(rest, LOG_LEVEL_ROLES[level] or "text")
    else
      print(line)
    end
  end
end

local function roll_back()
  if not is_admin() then
    return
  end
  local ok, err = blockos.pkg.rollback()
  if not ok then
    ui.print(err, "error")
    return
  end
  ui.print("Rolled back. Rebooting...", "ok")
  sleep(1)
  os.reboot()
end

-- blockos autologin <user>|off: log a local user in automatically at boot.
local function set_autologin(name)
  if not name then
    return print_usage()
  end
  if not is_admin() then
    return
  end
  if name == "off" then
    blockos.config.set("blockos.autologin", nil)
    return ui.print("Autologin turned off.", "ok")
  end
  if not blockos.auth.get(name) then
    return ui.print("No local user named " .. name .. ".", "error")
  end
  blockos.config.set("blockos.autologin", name)
  ui.print(name .. " is logged in automatically at boot.", "ok")
end

-- blockos motd <message...>|off: a message on the login screen.
local function set_motd(words)
  if #words == 0 then
    return print_usage()
  end
  if not is_admin() then
    return
  end
  local message = table.concat(words, " ")
  if message == "off" then
    blockos.config.set("blockos.motd", nil)
    return ui.print("Message of the day removed.", "ok")
  end
  blockos.config.set("blockos.motd", message)
  ui.print("Message of the day set.", "ok")
end

local function show_version()
  ui.title("BlockOS " .. blockos.version)
  local rows = {}
  for name, info in pairs(blockos.pkg.installed()) do
    rows[#rows + 1] = { name = name, version = info.version }
  end
  table.sort(rows, function(a, b) return a.name < b.name end)
  ui.table({ { title = "PACKAGE", key = "name" }, { title = "VERSION", key = "version" } }, rows)
end

local command = args[1] or "status"
if command == "status" then
  show_status()
elseif command == "services" then
  show_services()
elseif command == "start" or command == "stop" or command == "restart" then
  control_service(command, args[2])
elseif command == "log" then
  show_log(args[2])
elseif command == "cleanup" then
  clean_up()
elseif command == "autologin" then
  set_autologin(args[2])
elseif command == "motd" then
  set_motd({ table.unpack(args, 2) })
elseif command == "rollback" then
  roll_back()
elseif command == "version" then
  show_version()
else
  print_usage()
end
