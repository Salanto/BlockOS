--- Data kept on disk drives (floppies), spilling from one disk to the next.
--
-- A store keeps named entries (a table each, e.g. one mailbox per user) in a folder
-- on every place it may use: the computer itself (optional) and each disk in an
-- attached drive, directly or through wired modems. A new or grown entry goes to the
-- place it is already on if it still fits, else to the first place with room, and the
-- old copy is removed. A full disk simply means the next one is used.
-- @module diskstore

local fsx = import("fsx")

local diskstore = {}

--- Room kept free on every place (writes are atomic: old and new copy exist briefly).
diskstore.MARGIN = 2048

--- Hardware access (tests replace these).
diskstore.env = {
  peripheral = peripheral,
  disk = disk,
  free = nil, -- optional function(path) -> bytes (tests fake full disks)
}

-- Mount paths of every drive with a disk in it, sorted (a stable order to fill).
-- BlockOS install and package disks (index.lua at the top) are never used: they are
-- taken out again after installing.
local function disk_paths()
  local paths = {}
  local api, disk_api = diskstore.env.peripheral, diskstore.env.disk
  for _, name in ipairs(api.getNames()) do
    if api.hasType(name, "drive") and disk_api.hasData(name) then
      local path = disk_api.getMountPath(name)
      if path and not fs.exists(fs.combine(path, "index.lua")) then
        paths[#paths + 1] = "/" .. path
      end
    end
  end
  table.sort(paths)
  return paths
end

local function entry_path(place, key)
  return fs.combine(place, key)
end

-- Free bytes where a path is (or would be): the nearest folder that exists.
local function free_at(path)
  if diskstore.env.free then
    return diskstore.env.free(path)
  end
  local existing = fs.combine(path, "")
  while existing ~= "" and not fs.exists(existing) do
    existing = fs.getDir(existing)
  end
  return fs.getFreeSpace(existing == "" and "/" or existing)
end

--- Is there a floppy disk in an attached drive that a store could use?
-- @treturn boolean
function diskstore.has_disk()
  return #disk_paths() > 0
end

--- Open a store.
-- @tparam string folder Folder name on each place, e.g. "blockos-mail".
-- @tparam[opt] table options
--   computer       nil: disks only; "first": the computer before the disks (it spills
--                  to disks when full); "last": disks first, the computer after
--   computer_path  where on the computer (default "/var/<folder>")
-- @treturn table store
function diskstore.open(folder, options)
  options = options or {}
  local store = {}

  --- Every place the store may use right now, in the order they are filled.
  function store.places()
    local places = {}
    for _, path in ipairs(disk_paths()) do
      places[#places + 1] = fs.combine(path, folder)
    end
    local computer = options.computer_path or fs.combine("/var", folder)
    if options.computer == "first" then
      table.insert(places, 1, computer)
    elseif options.computer == "last" then
      places[#places + 1] = computer
    end
    for index, place in ipairs(places) do
      places[index] = "/" .. fs.combine(place, "")
    end
    return places
  end

  --- Is there anywhere to keep data at all?
  function store.has_place()
    return #store.places() > 0
  end

  -- Where an entry is now, if anywhere.
  local function find(key)
    for _, place in ipairs(store.places()) do
      if fs.exists(entry_path(place, key)) then
        return place
      end
    end
    return nil
  end

  --- Read an entry.
  -- @tparam string key
  -- @treturn table|nil
  function store.read(key)
    local place = find(key)
    return place and fsx.read_table(entry_path(place, key)) or nil
  end

  local function fits(place, size, old_size)
    return free_at(place) + old_size >= size + diskstore.MARGIN
  end

  --- Write an entry where it fits (its current place first).
  -- @tparam string key
  -- @tparam table value
  -- @treturn[1] string The place it went to.
  -- @treturn[2] nil
  -- @treturn[2] string error message
  function store.write(key, value)
    local text = textutils.serialise(value, { compact = true })
    local current = find(key)
    local old_size = current and fs.getSize(entry_path(current, key)) or 0
    local candidates = {}
    if current then
      candidates[1] = current
    end
    for _, place in ipairs(store.places()) do
      if place ~= current then
        candidates[#candidates + 1] = place
      end
    end
    if #candidates == 0 then
      return nil, "no disk: put a floppy disk into an attached disk drive"
    end
    for _, place in ipairs(candidates) do
      local is_current = place == current
      if fits(place, #text, is_current and old_size or 0) then
        local ok = pcall(fsx.write, entry_path(place, key), text)
        if ok then
          if current and not is_current then
            fs.delete(entry_path(current, key))
          end
          return place
        end
      end
    end
    return nil, "every disk is full: add another disk drive with a floppy"
  end

  --- Remove an entry.
  function store.delete(key)
    local place = find(key)
    if place then
      fs.delete(entry_path(place, key))
    end
    return true
  end

  --- Free bytes over every place, and how many places there are.
  -- @treturn number free
  -- @treturn number places
  function store.free()
    local free, places = 0, store.places()
    for _, place in ipairs(places) do
      local ok, bytes = pcall(free_at, place)
      free = free + (ok and bytes or 0)
    end
    return free, #places
  end

  return store
end

return diskstore
