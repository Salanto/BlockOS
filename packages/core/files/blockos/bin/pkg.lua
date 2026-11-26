-- pkg: manage optional BlockOS packages (an homage to apt/zypper).
--
--   pkg installed                       list installed packages
--   pkg list [source]                   list packages available from a source
--   pkg install <name...> [source] [--force]
--   pkg remove <name...>
--   pkg make-disk <name...> [source]    write an add-on disk
--   pkg publish <file.pkg> [--server[=name]]   upload to a package server
--
-- Sources: the latest GitHub release by default; --tag <tag> for a specific
-- release; --disk for a package disk in an attached drive; --server[=name] for
-- a package server (without a name: the domain's "pkg" service record). When the
-- blockos.pkg.server setting is set, that server is the default.
--
-- --force allows packages next to an exclusive one (e.g. the domain controller).
local args = { ... }

local ui = blockos.ui
local pkg = blockos.pkg

local function print_usage()
  print("Usage: pkg installed")
  print("       pkg list [--disk | --tag <tag> | --server[=name]]")
  print("       pkg install <name...> [source] [--force]")
  print("       pkg remove <name...>")
  print("       pkg make-disk <name...> [source]")
  print("       pkg publish <file.pkg> [--server[=name]]")
end

local function parse_args()
  local options = { names = {} }
  options.command = args[1]
  local i = 2
  while i <= #args do
    local flag = args[i]
    if flag == "--tag" then
      options.tag = args[i + 1]
      i = i + 1
    elseif flag == "--disk" then
      options.from_disk = true
    elseif flag == "--force" then
      options.force = true
    elseif flag == "--server" then
      options.from_server = true
    elseif flag:match("^%-%-server=") then
      options.from_server = true
      options.server_name = flag:match("^%-%-server=(.+)$")
    else
      options.names[#options.names + 1] = flag
    end
    i = i + 1
  end
  return options
end

-- Mount path of a disk in an attached drive; with `needs_index`, only a package disk.
local function find_disk(needs_index)
  for _, side in ipairs(peripheral.getNames()) do
    if peripheral.getType(side) == "drive" and disk.hasData(side) then
      local mount = "/" .. disk.getMountPath(side)
      if not needs_index or fs.exists(fs.combine(mount, "index.lua")) then
        return mount
      end
    end
  end
  return nil
end

local function show_progress(message)
  ui.print(message, "dim")
end

local function is_admin()
  if blockos.user and blockos.user.is_admin then
    return true
  end
  ui.print("Only administrators can change packages.", "error")
  return false
end

-- The package server client lives in the net package (base install).
local function server_source(name)
  local ok, pkg_remote = pcall(import, "pkg_remote")
  if not ok then
    return nil, "package servers need the net package"
  end
  local id, label = pkg_remote.find_server(name)
  if not id then
    return nil, label
  end
  return pkg_remote.source(id, label), id
end

local function choose_source(options)
  if options.from_disk then
    local dir = find_disk(true)
    if not dir then
      return nil, "no package disk found in an attached drive"
    end
    return pkg.disk_source(dir)
  end
  local default_server = blockos.config.get("blockos.pkg.server")
  local has_default_server = default_server ~= nil and default_server ~= ""
  local use_server = options.from_server or (not options.tag and has_default_server)
  if use_server then
    return server_source(options.server_name)
  end
  return pkg.github_source(options.tag)
end

local function apply_and_reboot(packages, apply_options)
  apply_options.progress = show_progress
  local ok, err = pkg.apply(packages, apply_options)
  if not ok then
    ui.print("Failed: " .. err, "error")
    return
  end
  ui.print("Done. Rebooting to load the changes...", "ok")
  sleep(2)
  os.reboot()
end

local function show_installed()
  local installed = pkg.installed()
  local names = {}
  for name in pairs(installed) do
    names[#names + 1] = name
  end
  table.sort(names)
  for _, name in ipairs(names) do
    print(string.format("%-14s %s", name, installed[name].version))
  end
end

local function show_available(source)
  local index, err = source.index()
  if not index then
    ui.print(err, "error")
    return
  end
  local installed = pkg.installed()
  local names = {}
  for name in pairs(index.packages) do
    names[#names + 1] = name
  end
  table.sort(names)
  for _, name in ipairs(names) do
    local entry = index.packages[name]
    local marks = {}
    if installed[name] then
      marks[#marks + 1] = "installed " .. installed[name].version
    end
    if entry.optional then
      marks[#marks + 1] = "optional"
    end
    print(string.format("%-14s %-10s %s", name, entry.version, table.concat(marks, ", ")))
  end
end

local function install(source, names, force)
  local index, err = source.index()
  if not index then
    ui.print(err, "error")
    return
  end
  local selected, select_error = pkg.select(index, names)
  if not selected then
    ui.print(select_error, "error")
    return
  end
  local fetched, packages = pkg.fetch(source, show_progress, selected)
  if not fetched then
    ui.print(packages, "error")
    return
  end
  apply_and_reboot(packages, { force = force })
end

local function remove(names)
  local installed = pkg.installed()
  for _, name in ipairs(names) do
    if not installed[name] then
      ui.print(name .. " is not installed.", "error")
      return
    end
  end
  apply_and_reboot({}, { remove = names })
end

local function make_disk(source, names)
  local dir = find_disk(false)
  if not dir then
    ui.print("Insert a floppy disk into an attached disk drive.", "error")
    return
  end
  local index, packages = pkg.fetch(source, show_progress, names)
  if not index then
    ui.print(packages, "error")
    return
  end
  local ok, err = pkg.write_media(dir, index, packages)
  if not ok then
    ui.print(err, "error")
    return
  end
  ui.print("Wrote " .. table.concat(names, ", ") .. " to " .. dir, "ok")
end

local function publish(options)
  local path = options.names[1]
  local full_path = path and shell.resolve(path)
  local raw = full_path and blockos.import("fsx").read_raw(full_path)
  if not raw then
    ui.print("No such package file: " .. tostring(path), "error")
    return
  end
  local ok, pkg_remote = pcall(import, "pkg_remote")
  if not ok then
    ui.print("Package servers need the net package.", "error")
    return
  end
  local id, label = pkg_remote.find_server(options.server_name)
  if not id then
    ui.print(label, "error")
    return
  end
  local result, err = pkg_remote.publish(id, raw)
  if not result then
    ui.print("Publish failed: " .. tostring(err), "error")
    return
  end
  ui.print("Published " .. tostring(result.name) .. " " .. tostring(result.version)
    .. " to " .. label .. ".", "ok")
end

local options = parse_args()
local command = options.command
local needs_names = command == "install" or command == "remove"
  or command == "make-disk" or command == "publish"

if command == "installed" then
  show_installed()
  return
end
if not (command == "list" or needs_names) or (needs_names and #options.names == 0) then
  print_usage()
  return
end
if command ~= "list" and not is_admin() then
  return
end
if command == "remove" then
  remove(options.names)
  return
end
if command == "publish" then
  publish(options)
  return
end

local source, source_error = choose_source(options)
if not source then
  ui.print(source_error, "error")
  return
end
if command == "list" then
  show_available(source)
elseif command == "install" then
  install(source, options.names, options.force)
else
  make_disk(source, options.names)
end
