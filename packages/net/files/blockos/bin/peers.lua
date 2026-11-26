-- peers: list the BlockOS devices this one can see. In a domain the list comes
-- from the domain controller (host names get the domain suffix); otherwise from
-- the announces this device has heard.
local ui = blockos.ui
local net = blockos.net

if not net then
  ui.print("The net service is not running.", "error")
  return
end
if not net.is_online() then
  ui.print("Offline: no modem attached.", "warn")
end

local function peers_from_directory(directory)
  local hosts, err = directory.list_hosts()
  if not hosts then
    ui.print("Could not ask the domain controller: " .. tostring(err), "error")
    return {}
  end
  for _, host in ipairs(hosts) do
    host.hostname = host.hostname .. "." .. directory.name()
  end
  return hosts
end

local directory = net.directory()
local peers
if directory then
  peers = peers_from_directory(directory)
else
  peers = net.peers()
end
if #peers == 0 then
  ui.print("No peers seen yet (devices announce every 5 minutes).", "dim")
  return
end

local function describe_extra(peer)
  local parts = {}
  local info = peer.info or {}
  if info.fuel ~= nil then
    parts[#parts + 1] = "fuel " .. tostring(info.fuel)
  end
  if type(info.position) == "table" then
    local p = info.position
    parts[#parts + 1] = string.format("@%d,%d,%d", p.x, p.y, p.z)
  end
  return table.concat(parts, " ")
end

-- Narrow screens (turtles, pockets) get fewer columns.
local width = ui.size()
local is_wide = width >= 45

ui.use("title")
if is_wide then
  print(string.format("%-16s %-5s %-8s %-9s %s", "HOST", "ID", "KIND", "VERSION", "SEEN"))
else
  print(string.format("%-16s %-5s %s", "HOST", "ID", "SEEN"))
end
ui.reset()

for _, peer in ipairs(peers) do
  local seen = peer.age and (math.floor(peer.age) .. "s") or "-"
  local line
  if is_wide then
    line = string.format("%-16s %-5d %-8s %-9s %s", ui.fit(peer.hostname, 16), peer.id or 0,
      ui.fit(peer.kind, 8), ui.fit(peer.version, 9), seen)
  else
    line = string.format("%-16s %-5d %s", ui.fit(peer.hostname, 16), peer.id or 0, seen)
  end
  print(ui.fit(line, width))
  local extra = describe_extra(peer)
  if extra ~= "" then
    ui.print("  " .. ui.fit(extra, width - 2), "dim")
  end
end
