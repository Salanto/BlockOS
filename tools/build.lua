-- Build release assets. Runs inside CraftOS-PC (see tools/build.sh):
--
--   build <version> <output dir> [repo dir]
--
-- Output:
--   <out>/index.lua          package list with versions, sizes and checksums
--   <out>/<name>.pkg         one file per package
--   <out>/install.lua        the online installer
--   <out>/disk/...           contents of an install floppy

local FLOPPY_CAPACITY_BYTES = 125000

local args = { ... }
local version = args[1] and args[1]:gsub("^v", "")
local out_dir = args[2]
local repo_dir = args[3] or "/repo"

if not version or not out_dir then
  printError("Usage: build <version> <output dir> [repo dir]")
  error("missing arguments", 0)
end

local kernel_dir = fs.combine(repo_dir, "packages/core/files/blockos/kernel")

local function import(name)
  local env = setmetatable({ import = import }, { __index = _G })
  local chunk = assert(loadfile(fs.combine(kernel_dir, name .. ".lua"), nil, env))
  return chunk()
end

local fsx = import("fsx")
local pkg = import("pkg")

local function load_manifest(package_dir)
  local chunk = assert(loadfile(fs.combine(package_dir, "package.lua"), nil, {}))
  local manifest = chunk()
  manifest.version = version
  return manifest
end

local function collect_files(package_dir)
  local files_dir = fs.combine(package_dir, "files")
  local files = {}
  for _, relative in ipairs(fsx.walk(files_dir)) do
    files[relative] = fsx.read_raw(fs.combine(files_dir, relative))
  end
  return files
end

local function build_package(name)
  local package_dir = fs.combine(repo_dir, "packages/" .. name)
  local bundle = {
    manifest = load_manifest(package_dir),
    files = collect_files(package_dir),
  }
  if bundle.manifest.name ~= name then
    error("package " .. name .. " has manifest name " .. tostring(bundle.manifest.name), 0)
  end
  return bundle, pkg.encode(bundle)
end

local index = { version = version, packages = {} }
local raw_packages = {}

for _, name in ipairs(fs.list(fs.combine(repo_dir, "packages"))) do
  local bundle, raw = build_package(name)
  raw_packages[name] = raw
  index.packages[name] = {
    version = bundle.manifest.version,
    depends = bundle.manifest.depends,
    optional = bundle.manifest.optional or nil,
    exclusive = bundle.manifest.exclusive or nil,
    size = #raw,
    sum = pkg.checksum(raw),
  }
  fsx.write_raw(fs.combine(out_dir, name .. ".pkg"), raw)
  print(string.format("%-6s %6d bytes", name, #raw))
end

local index_text = textutils.serialise(index)
fsx.write_raw(fs.combine(out_dir, "index.lua"), index_text)
fsx.write_raw(fs.combine(out_dir, "install.lua"),
  fsx.read_raw(fs.combine(repo_dir, "installer/install.lua")))

-- Write a floppy image holding some packages. With an installer it is a
-- bootable install disk; without one it is an add-on disk for `pkg install --disk`.
local function write_disk(dir_name, names, installer)
  local disk_dir = fs.combine(out_dir, dir_name)
  local disk_index = { version = version, packages = {} }
  local size = 0

  local function write_file(relative, data)
    fsx.write_raw(fs.combine(disk_dir, relative), data)
    size = size + #data
  end

  for _, name in ipairs(names) do
    disk_index.packages[name] = index.packages[name]
    write_file("packages/" .. name .. ".pkg", raw_packages[name])
  end
  write_file("index.lua", textutils.serialise(disk_index))
  if installer then
    write_file("startup.lua", installer)
  end

  print(string.format("%-14s %6d bytes (floppy holds %d)", dir_name, size, FLOPPY_CAPACITY_BYTES))
  if size > FLOPPY_CAPACITY_BYTES then
    error(dir_name .. " does not fit on a floppy", 0)
  end
end

-- The install disk carries only the required packages; each optional package
-- gets its own add-on disk, keeping the base install lean.
local required, optional = {}, {}
for name, entry in pairs(index.packages) do
  if entry.optional then
    optional[#optional + 1] = name
  else
    required[#required + 1] = name
  end
end
table.sort(required)
table.sort(optional)

local core = textutils.unserialise(raw_packages.core)
write_disk("disk", required, core.files["blockos/installer/disk.lua"])
for _, name in ipairs(optional) do
  write_disk("addon-" .. name, { name })
end

print("Built BlockOS " .. version .. " into " .. out_dir)
