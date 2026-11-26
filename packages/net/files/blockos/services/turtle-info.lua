-- turtle-info service: adds fuel, free inventory slots and (with GPS) position to
-- this turtle's announcements.
--
-- Only read-only turtle functions are used. This service must never move, dig or
-- change the selected slot, so it cannot interfere with the user's programs.

local REFRESH_SECONDS = 10
local GPS_INTERVAL_SECONDS = 60
local GPS_TIMEOUT_SECONDS = 2
local INVENTORY_SLOTS = 16

local function count_free_slots()
  local free = 0
  for slot = 1, INVENTORY_SLOTS do
    if turtle.getItemCount(slot) == 0 then
      free = free + 1
    end
  end
  return free
end

--- Read-only turtle status.
-- @treturn table { fuel, fuel_limit, free_slots }. fuel is a number, or
--   "unlimited" when fuel is disabled in the server config.
local function collect_status()
  return {
    fuel = turtle.getFuelLevel(),
    fuel_limit = turtle.getFuelLimit(),
    free_slots = count_free_slots(),
  }
end

local function locate()
  local x, y, z = gps.locate(GPS_TIMEOUT_SECONDS)
  if not x then
    return nil
  end
  return { x = math.floor(x), y = math.floor(y), z = math.floor(z) }
end

local function run()
  local last_gps_time = -math.huge
  local position = nil
  while true do
    local net = blockos.net
    if net then
      for key, value in pairs(collect_status()) do
        net.set_info(key, value)
      end
      if net.is_online() and os.clock() - last_gps_time >= GPS_INTERVAL_SECONDS then
        last_gps_time = os.clock()
        position = locate()
      end
      net.set_info("position", position)
    end
    sleep(REFRESH_SECONDS)
  end
end

return {
  name = "turtle-info",
  description = "Reports turtle fuel, inventory and position to peers",
  after = { "net" },
  condition = function() return blockos.device.kind() == "turtle" end,
  collect_status = collect_status,
  run = run,
}
