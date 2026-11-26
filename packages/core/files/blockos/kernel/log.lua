--- System log at /var/log/blockos.log, size-capped with one rotated copy (.1).
-- @module log

local paths = import("paths")

local log = {}

local LEVELS = { debug = 1, info = 2, warn = 3, error = 4 }
local MAX_LOG_BYTES = 16 * 1024

--- Messages below this level are dropped.
log.level = "info"

local function timestamp()
  local seconds = math.floor(os.epoch("utc") / 1000)
  return os.date("!%Y-%m-%d %H:%M:%S", seconds)
end

local function rotate_if_full(path)
  if not fs.exists(path) or fs.getSize(path) <= MAX_LOG_BYTES then
    return
  end
  local rotated = path .. ".1"
  if fs.exists(rotated) then
    fs.delete(rotated)
  end
  fs.move(path, rotated)
end

local function format_message(message, ...)
  if select("#", ...) == 0 then
    return tostring(message)
  end
  local ok, formatted = pcall(string.format, message, ...)
  if ok then
    return formatted
  end
  return tostring(message)
end

local function append_line(path, line)
  local dir = fs.getDir(path)
  if not fs.exists(dir) then
    fs.makeDir(dir)
  end
  rotate_if_full(path)
  local handle = fs.open(path, "ab")
  if handle then
    handle.write(line)
    handle.close()
  end
end

--- Write a log line. Never raises: logging must not crash the caller.
-- @tparam string level "debug", "info", "warn" or "error"
-- @tparam string source Who is logging, e.g. a service name.
-- @tparam string message A string.format pattern when extra arguments are given.
-- @param ... Format arguments.
function log.write(level, source, message, ...)
  if (LEVELS[level] or LEVELS.info) < (LEVELS[log.level] or LEVELS.info) then
    return
  end
  local text = format_message(message, ...)
  local line = string.format("%s [%s] %s: %s\n", timestamp(), level:upper(), source, text)
  pcall(append_line, paths.log(), line)
end

function log.debug(source, message, ...)
  log.write("debug", source, message, ...)
end

function log.info(source, message, ...)
  log.write("info", source, message, ...)
end

function log.warn(source, message, ...)
  log.write("warn", source, message, ...)
end

function log.error(source, message, ...)
  log.write("error", source, message, ...)
end

--- A logger bound to one source, e.g. `logger.info("started %s", name)`.
-- @tparam string source
-- @treturn table With debug, info, warn and error functions.
function log.logger(source)
  local logger = {}
  for level in pairs(LEVELS) do
    logger[level] = function(message, ...)
      log.write(level, source, message, ...)
    end
  end
  return logger
end

--- The last lines of the log.
-- @tparam number count
-- @treturn {string...} Oldest first.
function log.tail(count)
  local handle = fs.exists(paths.log()) and fs.open(paths.log(), "rb")
  if not handle then
    return {}
  end
  local data = handle.readAll() or ""
  handle.close()

  local lines = {}
  for line in data:gmatch("[^\n]+") do
    lines[#lines + 1] = line
  end
  local tail = {}
  for i = math.max(1, #lines - count + 1), #lines do
    tail[#tail + 1] = lines[i]
  end
  return tail
end

return log
