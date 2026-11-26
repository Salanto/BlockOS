--- Crash-safe file helpers.
--
-- CC gives no warning before a computer stops (chunk unload, server stop), so all
-- persistent state is written atomically: write `path.tmp`, delete `path`, then
-- move the temp file into place. Readers fall back to `path.tmp` when `path` is
-- missing, which covers a crash between the delete and the move.
-- @module fsx

local fsx = {}

local function ensure_parent_dir(path)
  local dir = fs.getDir(path)
  if dir ~= "" and not fs.exists(dir) then
    fs.makeDir(dir)
  end
end

--- Read a whole file as bytes.
-- @tparam string path
-- @treturn string|nil The contents, or nil if the file does not exist.
function fsx.read_raw(path)
  if not fs.exists(path) or fs.isDir(path) then
    return nil
  end
  local handle = fs.open(path, "rb")
  if not handle then
    return nil
  end
  local data = handle.readAll() or ""
  handle.close()
  return data
end

--- Write bytes to a file directly (not atomic), creating parent directories.
-- @tparam string path
-- @tparam string data
function fsx.write_raw(path, data)
  ensure_parent_dir(path)
  local handle, err = fs.open(path, "wb")
  if not handle then
    error("cannot write " .. path .. ": " .. tostring(err), 2)
  end
  handle.write(data)
  handle.close()
end

--- Atomically replace a file's contents.
-- @tparam string path
-- @tparam string data
function fsx.write(path, data)
  local tmp = path .. ".tmp"
  fsx.write_raw(tmp, data)
  if fs.exists(path) then
    fs.delete(path)
  end
  fs.move(tmp, path)
end

--- Read a file written with `fsx.write`, recovering from an interrupted write.
-- @tparam string path
-- @treturn string|nil
function fsx.read(path)
  return fsx.read_raw(path) or fsx.read_raw(path .. ".tmp")
end

--- Atomically write a table as serialised Lua.
-- @tparam string path
-- @tparam table value
function fsx.write_table(path, value)
  fsx.write(path, textutils.serialise(value))
end

--- Read a table written with `fsx.write_table`.
-- @tparam string path
-- @treturn table|nil The table, or nil if missing or unreadable.
function fsx.read_table(path)
  local data = fsx.read(path)
  if not data then
    return nil
  end
  local value = textutils.unserialise(data)
  if type(value) ~= "table" then
    return nil
  end
  return value
end

--- Delete a file and any leftover temp copy.
-- @tparam string path
function fsx.delete(path)
  if fs.exists(path) then
    fs.delete(path)
  end
  if fs.exists(path .. ".tmp") then
    fs.delete(path .. ".tmp")
  end
end

--- List all files below a directory.
-- @tparam string dir
-- @treturn {string...} Sorted paths relative to `dir`.
function fsx.walk(dir)
  local found = {}

  local function visit(current, relative)
    for _, name in ipairs(fs.list(current)) do
      local full = fs.combine(current, name)
      local rel = relative and (relative .. "/" .. name) or name
      if fs.isDir(full) then
        visit(full, rel)
      else
        found[#found + 1] = rel
      end
    end
  end

  visit(dir, nil)
  table.sort(found)
  return found
end

--- Total size of all files below a directory.
-- @tparam string dir
-- @treturn number Bytes (0 if the directory does not exist).
function fsx.tree_size(dir)
  if not fs.exists(dir) then
    return 0
  end
  local total = 0
  for _, relative in ipairs(fsx.walk(dir)) do
    total = total + fs.getSize(fs.combine(dir, relative))
  end
  return total
end

return fsx
