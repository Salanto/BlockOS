--- The .pkg format: encoding, decoding, checksums, content sums, package kinds.
-- (pkg offers these functions too.)
-- @module pkg_codec

local lz = import("lz")

local pkg_codec = {}

local CHECKSUM_CHUNK = 4096

------------------------------------------------------------------------------
-- Package files
------------------------------------------------------------------------------

--- Adler-32 checksum (detects corrupt downloads; not a security measure).
-- @tparam string data
-- @treturn number
function pkg_codec.checksum(data)
  local a, b = 1, 0
  for chunk_start = 1, #data, CHECKSUM_CHUNK do
    local chunk_end = math.min(chunk_start + CHECKSUM_CHUNK - 1, #data)
    local bytes = { data:byte(chunk_start, chunk_end) }
    for i = 1, #bytes do
      a = (a + bytes[i]) % 65521
      b = (b + a) % 65521
    end
  end
  return b * 65536 + a
end

-- A value as text with table keys in a fixed order, so equal content gives equal text.
local function canonical(value)
  if type(value) ~= "table" then
    return type(value) .. ":" .. tostring(value)
  end
  local keys = {}
  for key in pairs(value) do
    keys[#keys + 1] = key
  end
  table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
  local parts = {}
  for _, key in ipairs(keys) do
    parts[#parts + 1] = tostring(key) .. "=" .. canonical(value[key])
  end
  return "{" .. table.concat(parts, ",") .. "}"
end

--- A checksum of what a package contains, ignoring its version: the release build
-- keeps a package's old version while this stays the same ("last changed in").
-- @tparam table manifest
-- @tparam table files [path] = content
-- @treturn number
--- What each kind of package may ship. Packages are split by what a computer needs:
--   base         core and net (the base install): anything
--   protocol     a protocol's names, schemas and client library: libraries only
--   library      shared code for several applications: libraries only
--   application  what runs on a computer: at least one service (+ libraries, commands)
--   tools        commands and screens people use: at least one command, no services
--   bundle       nothing but dependencies (e.g. everything for a player's computer)
pkg_codec.KINDS = {
  base = { lib = true, bin = true, services = true, other = true },
  protocol = { lib = true },
  library = { lib = true },
  application = { lib = true, bin = true, services = true, needs = "services" },
  tools = { lib = true, bin = true, needs = "bin" },
  bundle = { needs = "depends" },
}

-- Which part of the tree a file belongs to: lib, bin, services or other.
local function part_of(path)
  local part = path:match("^blockos/([%w_]+)/")
  if part == "lib" or part == "kernel" then
    return "lib"
  elseif part == "bin" or part == "services" then
    return part
  end
  return "other"
end

--- Check that a package ships what its kind allows.
-- @tparam table manifest
-- @tparam table files [path] = content
-- @treturn[1] true
-- @treturn[2] nil
-- @treturn[2] string error message
function pkg_codec.check_kind(manifest, files)
  local rules = pkg_codec.KINDS[manifest.kind]
  if not rules then
    return nil, manifest.name .. ": kind must be one of base, protocol, library, application, "
      .. "tools or bundle"
  end
  local has = {}
  for path in pairs(files) do
    local part = part_of(path)
    if not rules[part] then
      return nil, string.format("%s is a %s package and may not ship %s", manifest.name,
        manifest.kind, path)
    end
    has[part] = true
  end
  if rules.needs == "depends" and next(manifest.depends or {}) == nil then
    return nil, manifest.name .. " is a bundle without dependencies"
  elseif rules.needs and rules.needs ~= "depends" and not has[rules.needs] then
    return nil, string.format("%s is a %s package but has no %s", manifest.name, manifest.kind,
      rules.needs)
  end
  return true
end

function pkg_codec.content_sum(manifest, files)
  local copy = {}
  for key, value in pairs(manifest) do
    if key ~= "version" then
      copy[key] = value
    end
  end
  local file_paths = {}
  for path in pairs(files) do
    file_paths[#file_paths + 1] = path
  end
  table.sort(file_paths)
  local parts = { canonical(copy) }
  for _, path in ipairs(file_paths) do
    parts[#parts + 1] = path .. "\0" .. files[path]
  end
  return pkg_codec.checksum(table.concat(parts, "\1"))
end


--- Serialise a package table and compress it.
-- @tparam table bundle { manifest, files }
-- @treturn string
function pkg_codec.encode(bundle)
  return lz.compress(textutils.serialise(bundle, { compact = true }))
end

--- Parse and validate a .pkg file (compressed with lz, or plain).
-- @tparam string raw
-- @treturn[1] table The package.
-- @treturn[2] nil
-- @treturn[2] string error message
function pkg_codec.decode(raw)
  local text, unpack_error = lz.unpack(raw)
  if not text then
    return nil, "damaged package: " .. unpack_error
  end
  local bundle = textutils.unserialise(text)
  if type(bundle) ~= "table"
    or type(bundle.manifest) ~= "table"
    or type(bundle.files) ~= "table" then
    return nil, "not a BlockOS package"
  end

  local manifest = bundle.manifest
  if type(manifest.name) ~= "string" or type(manifest.version) ~= "string" then
    return nil, "package manifest needs a name and version"
  end
  for path, content in pairs(bundle.files) do
    local is_valid = type(path) == "string" and type(content) == "string"
      and not path:find("%.%.")
    if not is_valid then
      return nil, "bad file entry in " .. manifest.name
    end
  end
  return bundle
end

--- Check a downloaded .pkg against its index entry.
-- @tparam string raw
-- @tparam table entry { size, sum } from index.lua.
-- @treturn[1] true
-- @treturn[2] nil
-- @treturn[2] string error message
function pkg_codec.verify(raw, entry)
  if entry.size and #raw ~= entry.size then
    return nil, string.format("size mismatch (%d, expected %d)", #raw, entry.size)
  end
  if entry.sum and pkg_codec.checksum(raw) ~= entry.sum then
    return nil, "checksum mismatch"
  end
  return true
end

return pkg_codec
