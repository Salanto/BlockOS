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

local function describe_seen(peer)
  if peer.age then
    return math.floor(peer.age) .. "s"
  elseif peer.days_unseen then
    return peer.days_unseen .. "d"
  end
  return "-"
end

-- Narrow screens (turtles, pockets) get fewer columns.
local width = ui.size()
local columns = { { title = "HOST", key = "hostname" }, { title = "ID", key = "id" } }
if width >= 45 then
  columns[#columns + 1] = { title = "KIND", key = "kind" }
  columns[#columns + 1] = { title = "VERSION", key = "version" }
end
columns[#columns + 1] = { title = "SEEN", key = describe_seen }
columns[#columns + 1] = { title = "INFO", key = describe_extra }

ui.title(directory and ("Domain " .. directory.name()) or "Peers nearby")
ui.table(columns, peers, function(peer)
  if peer.is_stale then
    return "faint"
  end
  return "text"
end)
