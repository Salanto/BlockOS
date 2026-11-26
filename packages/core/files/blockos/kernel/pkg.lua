--- Package manager: versions, package files, sources, crash-safe install.
--
-- A .pkg file is a serialised table:
--
--     { manifest = { name, version, depends = { core = ">=0.1" } },
--       files = { ["blockos/kernel/x.lua"] = "...contents..." } }
--
-- File paths are relative to the computer root. Files under "blockos/" make up
-- the system tree. Any other file is a default that is only written when it is
-- missing, so user files are never overwritten.
--
-- Installs and upgrades are crash-safe: the complete new tree is built in
-- /blockos.new and verified, then swapped in while a state marker is set. The
-- loader (/startup.lua) finishes or undoes an interrupted swap at boot. The
-- package database lives inside the tree (/blockos/packages.db), so it always
-- matches the files that are actually installed.
-- @module pkg

local fsx = import("fsx")
local paths = import("paths")

local pkg = {}

pkg.RELEASES_URL = "https://github.com/Salanto/BlockOS/releases"

local SPACE_MARGIN_BYTES = 4096
local CHECKSUM_CHUNK = 4096
local DISK_INSTALLER = "blockos/installer/disk.lua"

------------------------------------------------------------------------------
-- Versions
------------------------------------------------------------------------------

-- "v1.2.3-rc1" -> { 1, 2, 3 }, "rc1"
local function parse_version(version)
  local text = tostring(version):gsub("^v", "")
  local numbers_part, prerelease = text:match("^([%d%.]+)%-?(.*)$")
  if not numbers_part then
    return nil
  end
  local numbers = {}
  for number in numbers_part:gmatch("%d+") do
    numbers[#numbers + 1] = tonumber(number)
  end
  return numbers, prerelease
end

--- Compare two versions. A release sorts after its prereleases (0.1.0 > 0.1.0-rc1).
-- @tparam string a
-- @tparam string b
-- @treturn number -1, 0 or 1
function pkg.compare_versions(a, b)
  local numbers_a, pre_a = parse_version(a)
  local numbers_b, pre_b = parse_version(b)
  if not numbers_a or not numbers_b then
    if a == b then
      return 0
    end
    return tostring(a) < tostring(b) and -1 or 1
  end

  for i = 1, math.max(#numbers_a, #numbers_b) do
    local x = numbers_a[i] or 0
    local y = numbers_b[i] or 0
    if x ~= y then
      return x < y and -1 or 1
    end
  end

  if pre_a == pre_b then
    return 0
  elseif pre_a == "" then
    return 1
  elseif pre_b == "" then
    return -1
  end
  return pre_a < pre_b and -1 or 1
end

--- Check a version against a range.
-- @tparam string version
-- @tparam string range "*", "0.1.0", ">=0.1", ">0.1", "<=1.0", "<1.0" or "=0.2".
-- @treturn boolean
function pkg.satisfies(version, range)
  if range == nil or range == "*" or range == "" then
    return true
  end
  local operator, wanted = tostring(range):match("^%s*([<>=]*)%s*(.-)%s*$")
  local order = pkg.compare_versions(version, wanted)
  if operator == ">=" then
    return order >= 0
  elseif operator == ">" then
    return order > 0
  elseif operator == "<=" then
    return order <= 0
  elseif operator == "<" then
    return order < 0
  end
  return order == 0
end

------------------------------------------------------------------------------
-- Package files
------------------------------------------------------------------------------

--- Adler-32 checksum (detects corrupt downloads; not a security measure).
-- @tparam string data
-- @treturn number
function pkg.checksum(data)
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

--- Serialise a package table.
-- @tparam table bundle { manifest, files }
-- @treturn string
function pkg.encode(bundle)
  return textutils.serialise(bundle, { compact = true })
end

--- Parse and validate a .pkg file.
-- @tparam string raw
-- @treturn[1] table The package.
-- @treturn[2] nil
-- @treturn[2] string error message
function pkg.decode(raw)
  local bundle = textutils.unserialise(raw)
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
function pkg.verify(raw, entry)
  if entry.size and #raw ~= entry.size then
    return nil, string.format("size mismatch (%d, expected %d)", #raw, entry.size)
  end
  if entry.sum and pkg.checksum(raw) ~= entry.sum then
    return nil, "checksum mismatch"
  end
  return true
end

------------------------------------------------------------------------------
-- Installed packages
------------------------------------------------------------------------------

--- @tparam[opt] string root System tree, default paths.root().
-- @treturn string Path of the package database.
function pkg.db_path(root)
  return fs.combine(root or paths.root(), "packages.db")
end

--- Installed packages: { [name] = { version, depends, files = {...} } }.
-- @tparam[opt] string root
-- @treturn table
function pkg.installed(root)
  return fsx.read_table(pkg.db_path(root)) or {}
end

--- @tparam[opt] string root
-- @treturn string|nil Version of the installed core package.
function pkg.installed_version(root)
  local core = pkg.installed(root).core
  return core and core.version
end

--- @treturn boolean
function pkg.is_installed()
  return fs.exists(pkg.db_path())
end

--- Check that every dependency in a set of manifests is met.
-- @tparam table set { [name] = { version, depends } }
-- @treturn[1] true
-- @treturn[2] nil
-- @treturn[2] string error message
function pkg.check_depends(set)
  for name, manifest in pairs(set) do
    for dependency, range in pairs(manifest.depends or {}) do
      local found = set[dependency]
      if not found then
        return nil, string.format("%s needs %s, which is not installed", name, dependency)
      end
      if not pkg.satisfies(found.version, range) then
        return nil, string.format("%s needs %s %s (have %s)",
          name, dependency, range, found.version)
      end
    end
  end
  return true
end

------------------------------------------------------------------------------
-- Sources
--
-- A source has describe(), index() and fetch(name). index() and fetch() return
-- nil, err on failure. Layouts:
--   HTTP (release assets): <base>/index.lua and <base>/<name>.pkg
--   Disk:                  <dir>/index.lua  and <dir>/packages/<name>.pkg
------------------------------------------------------------------------------

--- A source reading from an install disk (or any directory).
-- @tparam string dir
-- @treturn table
function pkg.disk_source(dir)
  local source = {}

  function source.describe()
    return "disk " .. dir
  end

  function source.index()
    local index = fsx.read_table(fs.combine(dir, "index.lua"))
    if not index then
      return nil, "no index.lua on " .. dir
    end
    return index
  end

  function source.fetch(name)
    local raw = fsx.read_raw(fs.combine(dir, "packages/" .. name .. ".pkg"))
    if not raw then
      return nil, "missing " .. name .. ".pkg on " .. dir
    end
    return raw
  end

  return source
end

local function http_get(url)
  if not http then
    return nil, "the HTTP API is disabled on this server"
  end
  local response, err = http.get(url, nil, true)
  if not response then
    return nil, string.format("download failed: %s (%s)", tostring(err), url)
  end
  local body = response.readAll()
  response.close()
  return body
end

--- A source reading GitHub release assets.
--
-- Uses the plain download URLs, not api.github.com, whose 60 requests per hour
-- limit is shared by every computer on the server.
-- @tparam[opt] string tag e.g. "v0.1.0-rc1"; nil for the latest release.
-- @treturn table
function pkg.github_source(tag)
  local base
  if tag then
    base = pkg.RELEASES_URL .. "/download/" .. tag
  else
    base = pkg.RELEASES_URL .. "/latest/download"
  end
  local source = {}

  function source.describe()
    return tag and ("GitHub release " .. tag) or "the latest GitHub release"
  end

  function source.index()
    local raw, err = http_get(base .. "/index.lua")
    if not raw then
      return nil, err
    end
    local index = textutils.unserialise(raw)
    if type(index) ~= "table" then
      return nil, "the release index is unreadable"
    end
    return index
  end

  function source.fetch(name)
    return http_get(base .. "/" .. name .. ".pkg")
  end

  return source
end

--- Pick the packages to install from an index: every required (non-optional)
-- package, every package that is already installed, and any extra names asked for.
-- Dependencies of the chosen packages are added too.
-- @tparam table index
-- @tparam[opt] {string...} extra_names
-- @treturn[1] {string...} Sorted package names.
-- @treturn[2] nil
-- @treturn[2] string error message
function pkg.select(index, extra_names)
  local chosen = {}
  for name, entry in pairs(index.packages) do
    if not entry.optional then
      chosen[name] = true
    end
  end
  for name in pairs(pkg.installed()) do
    if index.packages[name] then
      chosen[name] = true
    end
  end
  for _, name in ipairs(extra_names or {}) do
    if not index.packages[name] then
      return nil, "no package named " .. name .. " in this source"
    end
    chosen[name] = true
  end

  -- Pull in dependencies until nothing new is added.
  local added = true
  while added do
    added = false
    for name in pairs(chosen) do
      for dependency in pairs(index.packages[name].depends or {}) do
        if index.packages[dependency] and not chosen[dependency] then
          chosen[dependency] = true
          added = true
        end
      end
    end
  end

  local names = {}
  for name in pairs(chosen) do
    names[#names + 1] = name
  end
  table.sort(names)
  return names
end

--- Download and verify packages from a source.
-- Each returned bundle keeps its original bytes in `raw`.
-- @tparam table source
-- @tparam[opt] function progress Called with status text.
-- @tparam[opt] {string...} names Packages to fetch; default pkg.select(index).
-- @treturn[1] table The index.
-- @treturn[1] {table...} The packages.
-- @treturn[2] nil
-- @treturn[2] string error message
function pkg.fetch(source, progress, names)
  progress = progress or function() end
  local index, index_error = source.index()
  if not index then
    return nil, index_error
  end
  if type(index.packages) ~= "table" then
    return nil, "the index has no package list"
  end
  if not names then
    local select_error
    names, select_error = pkg.select(index)
    if not names then
      return nil, select_error
    end
  end

  local packages = {}
  for _, name in ipairs(names) do
    if not index.packages[name] then
      return nil, "no package named " .. name .. " in this source"
    end
    progress("Fetching " .. name)
    local raw, fetch_error = source.fetch(name)
    if not raw then
      return nil, fetch_error
    end
    local ok, verify_error = pkg.verify(raw, index.packages[name])
    if not ok then
      return nil, name .. ": " .. verify_error
    end
    local bundle, decode_error = pkg.decode(raw)
    if not bundle then
      return nil, decode_error
    end
    bundle.raw = raw
    packages[#packages + 1] = bundle
  end
  return index, packages
end

------------------------------------------------------------------------------
-- Installing
------------------------------------------------------------------------------

local function set_upgrade_state(state)
  fsx.write(paths.upgrade_state(), state)
end

local function clear_upgrade_state()
  fsx.delete(paths.upgrade_state())
end

local function reset_bootcount()
  fsx.write(paths.bootcount(), "0")
end

-- Work out every file of the new tree.
-- tree[relative path] = { content = "..." } or { copy_from = "/blockos/..." }
-- outside[path] = content, for files outside the system tree.
local function plan_tree(new_packages, current, root, removed)
  local tree, outside, db, manifests = {}, {}, {}, {}

  local kept = {}
  for name in pairs(current) do
    if not removed[name] then
      kept[name] = true
    end
  end
  for _, bundle in ipairs(new_packages) do
    kept[bundle.manifest.name] = nil
  end

  for name in pairs(kept) do
    local info = current[name]
    for _, relative in ipairs(info.files or {}) do
      tree[relative] = { copy_from = fs.combine(root, relative) }
    end
    db[name] = info
    manifests[name] = info
  end

  for _, bundle in ipairs(new_packages) do
    local manifest = bundle.manifest
    local files = {}
    for path, content in pairs(bundle.files) do
      local relative = path:match("^blockos/(.+)$")
      if relative then
        tree[relative] = { content = content }
        files[#files + 1] = relative
      else
        outside[path] = content
      end
    end
    table.sort(files)
    db[manifest.name] = { version = manifest.version, depends = manifest.depends, files = files }
    manifests[manifest.name] = manifest
  end

  return tree, outside, db, manifests
end

local function check_space(tree, root)
  local needed = SPACE_MARGIN_BYTES
  for _, file in pairs(tree) do
    needed = needed + (file.content and #file.content or fs.getSize(file.copy_from))
  end
  -- Space held by the old copy and any old staging is freed during the install.
  local parent = fs.getDir(root)
  local free = fs.getFreeSpace(parent == "" and "/" or parent)
    + fsx.tree_size(paths.previous())
    + fsx.tree_size(paths.staging())
  if needed > free then
    return nil, string.format(
      "not enough disk space: need %d bytes but only %d are free. "
        .. "Free up at least %d bytes (for example delete old files or logs) and try again.",
      needed, free, needed - free)
  end
  return true
end

local function stage_tree(tree, staging)
  if fs.exists(staging) then
    fs.delete(staging)
  end
  for relative, file in pairs(tree) do
    local destination = fs.combine(staging, relative)
    if file.copy_from then
      if not fs.exists(file.copy_from) then
        return nil, "installed file missing: " .. file.copy_from
      end
      local dir = fs.getDir(destination)
      if not fs.exists(dir) then
        fs.makeDir(dir)
      end
      fs.copy(file.copy_from, destination)
    else
      fsx.write_raw(destination, file.content)
    end
  end
  return true
end

-- Every Lua file in the staged tree must at least compile.
local function verify_staged(tree, staging)
  for relative in pairs(tree) do
    if relative:match("%.lua$") then
      local source = fsx.read_raw(fs.combine(staging, relative))
      local chunk, err = load(source, "@" .. relative)
      if not chunk then
        return nil, "broken file in package: " .. tostring(err)
      end
    end
  end
  return true
end

-- Each step can be finished or undone by the loader after a crash.
local function swap_in(staging, root, previous)
  set_upgrade_state("swap")
  if fs.exists(root) then
    if fs.exists(previous) then
      fs.delete(previous)
    end
    fs.move(root, previous)
  end
  fs.move(staging, root)
end

local function write_missing_files(outside)
  for path, content in pairs(outside) do
    local destination = paths.top(path)
    if not fs.exists(destination) then
      fsx.write(destination, content)
    end
  end
end

--- Install, upgrade or remove packages.
--
-- Installed packages that are not in `new_packages` (or `options.remove`) are
-- kept as they are.
-- @tparam {table...} new_packages Decoded packages.
-- @tparam[opt] table options
--   progress (function) called with status text
--   remove   ({string...}) names of installed packages to remove
-- @treturn[1] true
-- @treturn[2] nil
-- @treturn[2] string error message
function pkg.apply(new_packages, options)
  options = options or {}
  local progress = options.progress or function() end
  local root, staging, previous = paths.root(), paths.staging(), paths.previous()

  local removed = {}
  for _, name in ipairs(options.remove or {}) do
    if name == "core" then
      return nil, "the core package cannot be removed"
    end
    removed[name] = true
  end

  local current = pkg.installed(root)
  local tree, outside, db, manifests = plan_tree(new_packages, current, root, removed)

  local ok, err = pkg.check_depends(manifests)
  if not ok then
    return nil, err
  end
  ok, err = check_space(tree, root)
  if not ok then
    return nil, err
  end

  -- The previous version is replaced by this install anyway; removing it now
  -- frees the space that check_space counted on.
  if fs.exists(previous) then
    fs.delete(previous)
  end

  -- The space check is an estimate; if the disk still fills up while staging,
  -- the write raises. Nothing live has been touched yet, so just clean up.
  progress("Staging files")
  local function stage_and_verify()
    local staged, stage_error = stage_tree(tree, staging)
    if not staged then
      return nil, stage_error
    end
    progress("Verifying")
    local verified, verify_error = verify_staged(tree, staging)
    if not verified then
      return nil, verify_error
    end
    fsx.write_table(fs.combine(staging, "packages.db"), db)
    return true
  end

  local completed, result, stage_error = pcall(stage_and_verify)
  if not completed or not result then
    if fs.exists(staging) then
      fs.delete(staging)
    end
    return nil, tostring(completed and stage_error or result)
  end

  progress("Installing")
  swap_in(staging, root, previous)
  write_missing_files(outside)
  clear_upgrade_state()
  reset_bootcount()
  return true
end

--- Swap the installed version with the previous one.
-- @treturn[1] true
-- @treturn[2] nil
-- @treturn[2] string error message
function pkg.rollback()
  local root, staging, previous = paths.root(), paths.staging(), paths.previous()
  if not fs.exists(fs.combine(previous, "boot.lua")) then
    return nil, "no previous version to roll back to"
  end
  if fs.exists(staging) then
    fs.delete(staging)
  end
  -- The loader knows how to finish each of these steps after a crash.
  set_upgrade_state("rollback")
  fs.move(root, staging)
  fs.move(previous, root)
  fs.move(staging, previous)
  clear_upgrade_state()
  reset_bootcount()
  return true
end

--- @treturn boolean True if /startup.lua is the BlockOS loader.
function pkg.has_loader()
  local current = fsx.read_raw(paths.startup())
  return current ~= nil and current:match("^%-%- BlockOS loader") ~= nil
end

local function move_into_backup(path, name)
  local backup = paths.startup_backup()
  if not fs.exists(backup) then
    fs.makeDir(backup)
  end
  local destination = fs.combine(backup, name)
  if fs.exists(destination) then
    fs.delete(destination)
  end
  fs.move(path, destination)
  return destination
end

--- Install the loader as /startup.lua, backing up a startup from another OS.
-- @tparam string loader_source
-- @treturn string|nil A note about what was backed up, if anything.
function pkg.install_loader(loader_source)
  local notes = {}
  if fs.exists(paths.startup()) and not pkg.has_loader() then
    local moved_to = move_into_backup(paths.startup(), "startup.lua")
    notes[#notes + 1] = "the old startup.lua was moved to " .. moved_to
  end
  if fs.exists(paths.startup_dir()) then
    local moved_to = move_into_backup(paths.startup_dir(), "startup")
    notes[#notes + 1] = "the old startup was moved to " .. moved_to
  end
  fsx.write(paths.startup(), loader_source)
  if #notes == 0 then
    return nil
  end
  return "Note: " .. table.concat(notes, "; ") .. "."
end

--- Write a package disk: index.lua and packages/ for the given packages.
--
-- If the packages include core, the disk installer is written as startup.lua,
-- which makes it a bootable install disk. Otherwise it is an add-on disk for
-- `pkg install --disk`; it has no startup, so it never takes over booting.
-- @tparam string dir Mount path of the disk.
-- @tparam table index The source index (entries are copied for these packages).
-- @tparam {table...} packages As returned by pkg.fetch (with `raw`).
-- @treturn[1] true
-- @treturn[2] nil
-- @treturn[2] string error message
function pkg.write_media(dir, index, packages)
  local installer = nil
  local disk_index = { version = index.version, packages = {} }
  for _, bundle in ipairs(packages) do
    local name = bundle.manifest.name
    disk_index.packages[name] = index.packages[name]
    if name == "core" then
      installer = bundle.files[DISK_INSTALLER]
    end
  end

  local index_text = textutils.serialise(disk_index)
  local needed = #index_text + (installer and #installer or 0)
  for _, bundle in ipairs(packages) do
    needed = needed + #bundle.raw
  end
  local packages_dir = fs.combine(dir, "packages")
  local free = fs.getFreeSpace(dir) + fsx.tree_size(packages_dir)
  if needed > free then
    return nil, string.format("the disk is too small (need %d bytes, %d free)", needed, free)
  end

  if fs.exists(packages_dir) then
    fs.delete(packages_dir)
  end
  for _, bundle in ipairs(packages) do
    fsx.write_raw(fs.combine(packages_dir, bundle.manifest.name .. ".pkg"), bundle.raw)
  end
  fsx.write(fs.combine(dir, "index.lua"), index_text)
  if installer then
    fsx.write(fs.combine(dir, "startup.lua"), installer)
  end
  return true
end

return pkg
