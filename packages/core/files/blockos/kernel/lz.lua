--- A small LZ77-style compressor for package files.
--
-- Lua source compresses to about half its size, which keeps the base install on
-- one 125KB floppy and halves downloads, package-server storage and rednet
-- transfers. Installed files are not compressed: they have to run.
--
-- The format is byte-oriented (no bit operations), so decompressing is just
-- copying bytes:
--
--   "BLZ1"  magic
--   4 bytes original length, little endian
--   then repeated sequences:
--     literal count (length code), that many literal bytes,
--     and, unless the data ends here:
--     match length - MIN_MATCH (length code), offset (2 bytes, little endian)
--
-- A length code is a run of 255 bytes plus one final byte below 255; the value
-- is their sum.
--
-- This module imports nothing, so installers can load it on its own before any
-- package has been unpacked.
-- @module lz

local lz = {}

lz.MAGIC = "BLZ1"

local MIN_MATCH = 4
local MAX_MATCH = 1024
local MAX_OFFSET = 65535
local MAX_CANDIDATES = 16
local SECONDS_BETWEEN_YIELDS = 0.5

-- Let other coroutines run during long work: CC stops code that runs too long
-- without yielding. Time-based, because the work per step varies a lot.
local last_yield = os.clock()
lz.stats = rawget(_G, "LZ_STATS") or { yields = 0, wait = 0, skipped = 0 } -- EXPERIMENT
rawset(_G, "LZ_STATS", lz.stats)
local function take_a_breath_if_needed()
  if os.clock() - last_yield >= SECONDS_BETWEEN_YIELDS then
    local started = os.epoch("utc")
    os.queueEvent("blockos_lz")
    while true do
      local event = os.pullEvent()
      if event == "blockos_lz" then
        break
      end
      lz.stats.skipped = lz.stats.skipped + 1
      lz.stats.last_skipped = event
    end
    lz.stats.yields = lz.stats.yields + 1
    lz.stats.wait = lz.stats.wait + (os.epoch("utc") - started)
    last_yield = os.clock()
  end
end

-- Little-endian unsigned numbers (string.pack: CC:Tweaked has it, see the
-- feature compatibility list).
local function encode_u32(value)
  return string.pack("<I4", value)
end

local function decode_u32(data, position)
  return (string.unpack("<I4", data, position))
end

local function put_length(parts, value)
  while value >= 255 do
    parts[#parts + 1] = "\255"
    value = value - 255
  end
  parts[#parts + 1] = string.char(value)
end

--- @tparam string data
-- @treturn boolean True if `data` is compressed with this module.
function lz.is_compressed(data)
  return data:sub(1, #lz.MAGIC) == lz.MAGIC
end

-- Length of the common prefix of data[a..] and data[b..], up to `limit`.
local function match_length(data, a, b, limit)
  local length = 0
  while length < limit and data:byte(a + length) == data:byte(b + length) do
    length = length + 1
  end
  return length
end

--- Compress a string.
-- @tparam string data
-- @treturn string
function lz.compress(data)
  local size = #data
  local parts = { lz.MAGIC, encode_u32(size) }
  local latest = {}   -- [4-byte string] = most recent position
  local previous = {} -- [position] = earlier position with the same 4 bytes
  local literal_start = 1
  local position = 1

  local function remember(at)
    local key = data:sub(at, at + MIN_MATCH - 1)
    previous[at] = latest[key]
    latest[key] = at
  end

  while position <= size - MIN_MATCH + 1 do
    local best_length, best_offset = 0, 0
    local candidate = latest[data:sub(position, position + MIN_MATCH - 1)]
    local tries = 0
    local limit = math.min(MAX_MATCH, size - position + 1)
    while candidate and position - candidate <= MAX_OFFSET and tries < MAX_CANDIDATES do
      local length = match_length(data, candidate, position, limit)
      if length > best_length then
        best_length, best_offset = length, position - candidate
      end
      candidate = previous[candidate]
      tries = tries + 1
    end

    if best_length >= MIN_MATCH then
      put_length(parts, position - literal_start)
      parts[#parts + 1] = data:sub(literal_start, position - 1)
      put_length(parts, best_length - MIN_MATCH)
      parts[#parts + 1] = string.pack("<I2", best_offset)
      for at = position, position + best_length - 1 do
        remember(at)
      end
      position = position + best_length
      literal_start = position
    else
      remember(position)
      position = position + 1
    end

    take_a_breath_if_needed()
  end

  put_length(parts, size - literal_start + 1)
  parts[#parts + 1] = data:sub(literal_start)
  return table.concat(parts)
end

--- Decompress a string made by lz.compress.
-- @tparam string data
-- @treturn[1] string
-- @treturn[2] nil
-- @treturn[2] string error message
function lz.decompress(data)
  if not lz.is_compressed(data) or #data < 8 then
    return nil, "not compressed data"
  end
  local expected = decode_u32(data, 5)
  local output = {}
  local count = 0
  local position = 9

  local function read_length()
    local total = 0
    while true do
      local byte = data:byte(position)
      if not byte then
        error("compressed data is cut short", 0)
      end
      position = position + 1
      total = total + byte
      if byte < 255 then
        return total
      end
    end
  end

  local ok, err = pcall(function()
    while position <= #data do
      local literals = read_length()
      for at = position, position + literals - 1 do
        count = count + 1
        output[count] = data:sub(at, at)
      end
      position = position + literals
      if position > #data then
        break
      end

      local length = read_length() + MIN_MATCH
      if position + 1 > #data then
        error("compressed data is cut short", 0)
      end
      local offset = string.unpack("<I2", data, position)
      position = position + 2
      if offset == 0 or offset > count then
        error("compressed data is corrupt", 0)
      end
      -- Byte by byte: a match may overlap the bytes it is producing.
      for _ = 1, length do
        count = count + 1
        output[count] = output[count - offset]
      end
      take_a_breath_if_needed()
    end
  end)
  if not ok then
    return nil, err
  end

  local result = table.concat(output)
  if #result ~= expected then
    return nil, "compressed data has the wrong length"
  end
  return result
end

--- Decompress if compressed, otherwise return the data unchanged.
-- @tparam string data
-- @treturn[1] string
-- @treturn[2] nil
-- @treturn[2] string error message
function lz.unpack(data)
  if lz.is_compressed(data) then
    return lz.decompress(data)
  end
  return data
end

return lz
