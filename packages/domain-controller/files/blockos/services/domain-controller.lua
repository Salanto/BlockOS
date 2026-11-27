-- domain-controller service: serves the domain directory over rednet.
--
-- The directory is saved to /etc/blockos/directory after every change, but only
-- when the disk has room for it; otherwise changes are refused and logged. User
-- sessions are saved to /etc/blockos/sessions so logins survive a restart;
-- status reports stay in memory. Every few minutes the
-- service drops expired sessions and warns when the disk is getting full.
-- Only runs once `dcpromo` has created the domain.

local DIRECTORY_FILE = "etc/blockos/directory"
local SESSIONS_FILE = "etc/blockos/sessions"
local SAVE_MARGIN_BYTES = 8 * 1024
local LOW_SPACE_FRACTION = 0.2
local HOUSEKEEPING_SECONDS = 300

local function directory_path()
  return import("paths").top(DIRECTORY_FILE)
end

local function run(ctx)
  local dc_handlers = import("dc_handlers")
  local directory = import("directory")
  local fsx = import("fsx")
  local rpc = import("rpc")
  local log = ctx.log

  local path = directory_path()
  local data = fsx.read_table(path)
  if not data then
    error("the directory file is missing or unreadable", 0)
  end
  -- A save interrupted after its temp file was complete: keep the real file.
  if fs.exists(path) and fs.exists(path .. ".tmp") then
    fs.delete(path .. ".tmp")
  end
  local sessions_path = import("paths").top(SESSIONS_FILE)
  local dir = directory.load(data, fsx.read_table(sessions_path))

  -- Real seconds, so session lifetimes survive restarts.
  local function now()
    return math.floor(os.epoch("utc") / 1000)
  end
  dir:prune_sessions(now())
  local disk_dir = fs.getDir(path)

  local function disk_status()
    local capacity = fs.getCapacity and fs.getCapacity(disk_dir) or nil
    return { free = fs.getFreeSpace(disk_dir), capacity = capacity }
  end

  -- An atomic save needs room for a full second copy while it runs. The size is the
  -- file's as last saved (serialising the whole directory just to ask would cost as
  -- much as saving); the margin covers one change's growth.
  local function has_room()
    local size = fs.exists(path) and fs.getSize(path) or 0
    return fs.getFreeSpace(disk_dir) >= size + SAVE_MARGIN_BYTES
  end

  local function save()
    local ok, err = pcall(fsx.write_table, path, dir.data)
    if not ok then
      log.error("could not save the directory: %s", tostring(err))
      if fs.exists(path .. ".tmp") and fs.exists(path) then
        fs.delete(path .. ".tmp")
      end
      return nil, dc_handlers.DISK_FULL
    end
    return true
  end

  local function save_sessions()
    pcall(fsx.write_table, sessions_path, dir:saved_sessions())
  end

  local storage = {
    save = save,
    has_room = has_room,
    disk_status = disk_status,
    save_sessions = save_sessions,
  }

  -- The controller can check tokens itself, without a network round trip.
  rpc.set_computer_validator(function(computer_token)
    local hostname = dir:computer_by_token(computer_token)
    return hostname and { hostname = hostname }
  end)
  rpc.set_user_validator(function(token)
    return dir:validate(token, now())
  end)

  local was_low = false
  local function housekeeping()
    while true do
      local removed = dir:prune_sessions(now())
      if removed > 0 then
        log.info("dropped %d expired sessions", removed)
        save_sessions()
      end
      local disk = disk_status()
      local is_low = disk.capacity and disk.free < disk.capacity * LOW_SPACE_FRACTION
        or not has_room()
      if is_low and not was_low then
        log.warn("disk space is low: %d bytes free", disk.free)
      elseif was_low and not is_low then
        log.info("disk space is fine again: %d bytes free", disk.free)
      end
      was_low = is_low
      sleep(HOUSEKEEPING_SECONDS)
    end
  end

  -- Hosting under the domain name lets computers find us with rednet.lookup.
  if rednet.isOpen() then
    rednet.host(import("domain").PROTOCOL, dir:name())
  end
  log.info("serving domain %s", dir:name())
  parallel.waitForAny(
    function() rpc.serve(import("domain").PROTOCOL, dc_handlers.new(dir, storage)) end,
    housekeeping
  )
end

return {
  name = "domain-controller",
  description = "Domain directory: users, groups, computers, names and services",
  after = { "net" },
  restart = "on-failure",
  condition = function() return fs.exists(directory_path()) end,
  run = run,
}
