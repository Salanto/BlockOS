-- Build release assets. Runs inside CraftOS-PC (see tools/build.sh):
--
--   build <version> <output dir> [repo dir]
--
-- Versions: each package keeps the version of the release it last changed in. If
-- <repo>/tools/previous-index.lua exists (tools/build.sh downloads the latest release's
-- index.lua there), a package whose content checksum (pkg.content_sum) matches keeps its
-- previous version; every other package gets <version>.
--
-- Output:
--   <out>/index.lua          package list with versions, sizes, checksums and content sums
--   <out>/<name>.pkg         one file per package
--   <out>/install.lua        the online installer
--   <out>/lz.lua             the decompressor the installers load first
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
  return chunk()
end

-- The previous release's index, if tools/build.sh could download it.
local function load_previous_index()
  local path = fs.combine(repo_dir, "tools/previous-index.lua")
  local text = fs.exists(path) and fsx.read_raw(path)
  local index = text and textutils.unserialise(text)
  if type(index) ~= "table" or type(index.packages) ~= "table" then
    print("No previous release index: every package gets " .. version)
    return { packages = {} }
  end
  print("Comparing with release " .. tostring(index.version))
  return index
end
local previous = load_previous_index()

-- Shrink a Lua file so the base install fits on a floppy, without changing line
-- numbers: comment-only lines become empty and indentation is dropped, so an
-- error on a computer still points at the right line of the readable source in
-- the repository. Line 1 is kept as is (the loader is recognised by it).
local function shrink_lua(path, source)
  if source:find("[[", 1, true) then
    error(path .. ": long strings/comments ([[ ]]) are not supported by the build", 0)
  end
  local lines = {}
  for line in (source .. "\n"):gmatch("(.-)\r?\n") do
    if #lines == 0 then
      lines[1] = line
    else
      local trimmed = line:match("^%s*(.-)%s*$")
      if trimmed:sub(1, 2) == "--" then
        trimmed = ""
      end
      lines[#lines + 1] = trimmed
    end
  end
  return table.concat(lines, "\n")
end

local function collect_files(package_dir)
  local files_dir = fs.combine(package_dir, "files")
  local files = {}
  if not fs.isDir(files_dir) then
    return files
  end
  for _, relative in ipairs(fsx.walk(files_dir)) do
    local content = fsx.read_raw(fs.combine(files_dir, relative))
    if relative:match("%.lua$") then
      content = shrink_lua(relative, content)
    end
    files[relative] = content
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
  local ok, kind_error = pkg.check_kind(bundle.manifest, bundle.files)
  if not ok then
    error(kind_error, 0)
  end
  -- "Last changed in": unchanged content keeps the previous release's version.
  local content = pkg.content_sum(bundle.manifest, bundle.files)
  local before = previous.packages[name]
  local is_unchanged = before and before.content == content and before.version
  bundle.manifest.version = is_unchanged and before.version or version
  return bundle, pkg.encode(bundle), content, not is_unchanged
end

local index = { version = version, packages = {} }
local raw_packages = {}

for _, name in ipairs(fs.list(fs.combine(repo_dir, "packages"))) do
  local bundle, raw, content, is_changed = build_package(name)
  raw_packages[name] = raw
  index.packages[name] = {
    version = bundle.manifest.version,
    content = content,
    depends = bundle.manifest.depends,
    optional = bundle.manifest.optional or nil,
    exclusive = bundle.manifest.exclusive or nil,
    kind = bundle.manifest.kind,
    -- shown when choosing packages (dsa's computer roles)
    description = bundle.manifest.description,
    size = #raw,
    sum = pkg.checksum(raw),
  }
  fsx.write_raw(fs.combine(out_dir, name .. ".pkg"), raw)
  print(string.format("%-22s %-10s %6d bytes  %s", name, bundle.manifest.version, #raw,
    is_changed and "changed" or "unchanged"))
end

local index_text = textutils.serialise(index)
fsx.write_raw(fs.combine(out_dir, "index.lua"), index_text)
fsx.write_raw(fs.combine(out_dir, "install.lua"),
  fsx.read_raw(fs.combine(repo_dir, "installer/install.lua")))

-- Write a floppy image holding some packages. With an installer it is a
-- bootable install disk (with the decompressor it needs); without one it is an
-- add-on disk for `pkg install --disk`.
local function write_disk(dir_name, names, installer, decompressor)
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
    write_file("lz.lua", decompressor)
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

local core = assert(pkg.decode(raw_packages.core))
local decompressor = core.files["blockos/kernel/lz.lua"]
fsx.write_raw(fs.combine(out_dir, "lz.lua"), decompressor)
write_disk("disk", required, core.files["blockos/installer/disk.lua"], decompressor)
for _, name in ipairs(optional) do
  write_disk("addon-" .. name, { name })
end

print("Built BlockOS " .. version .. " into " .. out_dir)
