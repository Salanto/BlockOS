--- Package manager: the installed database, choosing packages, crash-safe install
-- (versions: pkg_version; the .pkg format: pkg_codec; sources: pkg_sources).
--
-- A .pkg file is a serialised table, compressed with lz (see lz.lua):
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

local SPACE_MARGIN_BYTES = 4096

-- Versions, the package format and the sources are their own modules; pkg offers their
-- functions too, so callers use pkg alone.
for _, part in ipairs({ "pkg_version", "pkg_codec", "pkg_sources" }) do
  for name, value in pairs(import(part)) do
    pkg[name] = value
  end
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
        -- Both an install missing a dependency and a removal taking one away end here.
        return nil, string.format("%s needs %s: remove %s too, or keep (install) %s",
          name, dependency, name, dependency)
      end
      if not pkg.satisfies(found.version, range) then
        return nil, string.format("%s needs %s %s (have %s)",
          name, dependency, range, found.version)
      end
    end
  end
  return true
end

--- Which of these packages an update would change: new ones and ones whose version
-- in the source differs from the installed one.
-- @tparam table index A source index.
-- @tparam {string...} names Packages to consider (e.g. from pkg.select).
-- @tparam[opt] table installed Default: pkg.installed().
-- @treturn {table...} { name, from (nil when new), to }, sorted by name
function pkg.changes(index, names, installed)
  installed = installed or pkg.installed()
  local list = {}
  for _, name in ipairs(names) do
    local entry = index.packages[name]
    local have = installed[name] and installed[name].version
    if entry and have ~= entry.version then
      list[#list + 1] = { name = name, from = have, to = entry.version }
    end
  end
  table.sort(list, function(a, b) return a.name < b.name end)
  return list
end

--- Pick the packages to install from an index: every required (non-optional)
-- package, every package that is already installed, and any extra names asked for.
-- Dependencies of the chosen packages are added too.
-- @tparam table index
-- @tparam[opt] {string...} extra_names
-- @tparam[opt] table installed Installed packages (default: pkg.installed()).
-- @treturn[1] {string...} Sorted package names.
-- @treturn[2] nil
-- @treturn[2] string error message
function pkg.select(index, extra_names, installed)
  local chosen = {}
  for name, entry in pairs(index.packages) do
    if not entry.optional then
      chosen[name] = true
    end
  end
  for name in pairs(installed or pkg.installed()) do
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

-- Files listed in a manifest's `media_only` (path prefixes) are not installed.
local function is_media_only(manifest, path)
  for _, prefix in ipairs(manifest.media_only or {}) do
    if path:sub(1, #prefix) == prefix then
      return true
    end
  end
  return false
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
      local is_installed = not is_media_only(manifest, path)
      if is_installed and relative then
        tree[relative] = { content = content }
        files[#files + 1] = relative
      elseif is_installed then
        outside[path] = content
      end
    end
    table.sort(files)
    db[manifest.name] = {
      version = manifest.version,
      depends = manifest.depends,
      optional = manifest.optional,
      exclusive = manifest.exclusive,
      roles = manifest.roles, -- directory roles for managed mode (see the domain's roles.lua)
      kind = manifest.kind,
      companions = manifest.companions,
      files = files,
    }
    manifests[manifest.name] = manifest
  end

  return tree, outside, db, manifests
end

-- Names a package depends on, directly or indirectly.
local function dependency_closure(name, manifests)
  local found = {}
  local function visit(current)
    for dependency in pairs((manifests[current] or {}).depends or {}) do
      if not found[dependency] then
        found[dependency] = true
        visit(dependency)
      end
    end
  end
  visit(name)
  return found
end

-- An exclusive package (e.g. the domain controller) must run alone: no other
-- optional packages next to it, except its own dependencies.
local function check_exclusive(manifests)
  for name, manifest in pairs(manifests) do
    if manifest.exclusive then
      local allowed = dependency_closure(name, manifests)
      -- Companions (manifest `companions`) may run next to it, with what they need.
      for _, companion in ipairs(manifest.companions or {}) do
        if manifests[companion] then
          allowed[companion] = true
          for needed in pairs(dependency_closure(companion, manifests)) do
            allowed[needed] = true
          end
        end
      end
      for other, other_manifest in pairs(manifests) do
        if other ~= name and other_manifest.optional and not allowed[other] then
          return nil, string.format(
            "%s must run alone on its computer, but %s is also installed. "
              .. "Use --force to allow it anyway.", name, other)
        end
      end
    end
  end
  return true
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
--   force    (boolean) allow other packages next to an exclusive one
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
  -- A package that took over another one (manifest `replaces`) removes it, so
  -- installing logistics-node retires storage-monitor.
  for _, bundle in ipairs(new_packages) do
    for _, name in ipairs(bundle.manifest.replaces or {}) do
      if name ~= "core" then
        removed[name] = true
      end
    end
  end

  local current = pkg.installed(root)
  local tree, outside, db, manifests = plan_tree(new_packages, current, root, removed)

  local ok, err = pkg.check_depends(manifests)
  if not ok then
    return nil, err
  end
  if not options.force then
    ok, err = check_exclusive(manifests)
    if not ok then
      return nil, err
    end
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

return pkg
