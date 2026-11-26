-- pkg: manage optional BlockOS packages (an homage to apt/zypper).
--
--   pkg installed                       list installed packages
--   pkg list [--disk | --tag <tag>]     list packages available from a source
--   pkg install <name...> [--disk | --tag <tag>]
--   pkg remove <name...>
--   pkg make-disk <name...> [--tag <tag>]   write an add-on disk
--
-- Sources: the latest GitHub release by default, a specific release with --tag,
-- or a package disk in an attached drive with --disk. A future central package
-- server on the network would be one more source.
local args = { ... }

local ui = blockos.ui
local pkg = blockos.pkg

local function print_usage()
  print("Usage: pkg installed")
  print("       pkg list [--disk | --tag <tag>]")
  print("       pkg install <name...> [--disk | --tag <tag>]")
  print("       pkg remove <name...>")
  print("       pkg make-disk <name...> [--tag <tag>]")
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

local function choose_source(options)
  if not options.from_disk then
    return pkg.github_source(options.tag)
  end
  local dir = find_disk(true)
  if not dir then
    return nil, "no package disk found in an attached drive"
  end
  return pkg.disk_source(dir)
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

local function install(source, names)
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
  apply_and_reboot(packages, {})
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

local options = parse_args()
local command = options.command
local needs_names = command == "install" or command == "remove" or command == "make-disk"

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

local source, source_error = choose_source(options)
if not source then
  ui.print(source_error, "error")
  return
end
if command == "list" then
  show_available(source)
elseif command == "install" then
  install(source, options.names)
else
  make_disk(source, options.names)
end
