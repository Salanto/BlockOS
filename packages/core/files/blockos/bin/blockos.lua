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
  print("  blockos version")
end

local function is_admin()
  if blockos.user and blockos.user.is_admin then
    return true
  end
  ui.print("Only administrators can do that.", "error")
  return false
end

local function show_status()
  local device = blockos.device
  local hardware = device.is_advanced() and "advanced" or "basic"
  ui.print("BlockOS " .. blockos.version, "title")
  print("Device:   " .. hardware .. " " .. device.kind())
  print("Computer: #" .. os.getComputerID() .. " " .. (os.getComputerLabel() or ""))
  if blockos.net then
    print("Hostname: " .. tostring(blockos.net.hostname()))
  end
  print("User:     " .. (blockos.user and blockos.user.name or "-"))
  print("Uptime:   " .. math.floor(os.clock()) .. "s")

  local counts = {}
  for _, service in ipairs(services.list()) do
    counts[service.state] = (counts[service.state] or 0) + 1
  end
  local parts = {}
  for state, count in pairs(counts) do
    parts[#parts + 1] = count .. " " .. state
  end
  table.sort(parts)
  print("Services: " .. table.concat(parts, ", "))
end

local function show_services()
  for _, service in ipairs(services.list()) do
    ui.use("text")
    write(string.format("%-14s ", service.name))
    ui.print(service.state, STATE_ROLES[service.state] or "dim")
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

local function show_log(count)
  for _, line in ipairs(blockos.log.tail(tonumber(count) or 15)) do
    print(line)
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

local function show_version()
  print("BlockOS " .. blockos.version)
  for name, info in pairs(blockos.pkg.installed()) do
    print(string.format("  %-10s %s", name, info.version))
  end
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
elseif command == "rollback" then
  roll_back()
elseif command == "version" then
  show_version()
else
  print_usage()
end
