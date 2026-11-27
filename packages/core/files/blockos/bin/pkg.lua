-- pkg: manage optional BlockOS packages (an homage to apt/zypper).
--
--   pkg installed                       list installed packages
--   pkg list [source]                   list packages available from a source
--   pkg install <name...> [source] [--force]
--   pkg remove <name...>
--   pkg update [source] [--check] [-y] [--force]
--                                       upgrade BlockOS and installed packages
--   pkg publish <file.pkg> [--server[=name]]   upload to a package server
--
-- Sources: a package server when one is found (the blockos.pkg.server setting,
-- the domain's "pkg" service record, or one answering on the network), else
-- the latest GitHub release. --server[=name], --github, --tag <tag> (a GitHub
-- release) and --disk (a package disk in an attached drive) pick one.
--
-- --force allows packages next to an exclusive one (e.g. the domain controller).
local args = { ... }

local ui = blockos.ui
local pkg = blockos.pkg

local function print_usage()
  print("Usage: pkg installed")
  print("       pkg list [source]")
  print("       pkg install <name...> [source] [--force]")
  print("       pkg remove <name...>")
  print("       pkg update [source] [--check] [-y] [--force]")
  print("       pkg publish <file.pkg> [--server[=name]]")
  print("Source: --server[=name] | --github | --tag <tag> | --disk")
  print("        (default: a package server if found, else GitHub)")
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
    elseif flag == "--github" then
      options.from_github = true
    elseif flag == "--check" then
      options.check_only = true
    elseif flag == "-y" or flag == "--yes" then
      options.assume_yes = true
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

-- Mount path of a package disk (one with index.lua) in an attached drive.
local function find_package_disk()
  for _, side in ipairs(peripheral.getNames()) do
    if peripheral.getType(side) == "drive" and disk.hasData(side) then
      local mount = "/" .. disk.getMountPath(side)
      if fs.exists(fs.combine(mount, "index.lua")) then
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
    local dir = find_package_disk()
    if not dir then
      return nil, "no package disk found in an attached drive"
    end
    return pkg.disk_source(dir)
  end
  if options.from_server then
    return server_source(options.server_name)
  end
  if options.tag or options.from_github then
    return pkg.github_source(options.tag)
  end
  -- Nothing chosen: a package server if one can be found, else GitHub.
  local source = server_source(nil)
  if source then
    return source
  end
  return pkg.github_source()
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
  local rows = {}
  for name, info in pairs(pkg.installed()) do
    local kind = info.kind or (info.optional and "optional" or "base")
    if info.exclusive then
      kind = kind .. ", alone"
    end
    rows[#rows + 1] = { name = name, version = info.version, kind = kind }
  end
  table.sort(rows, function(a, b) return a.name < b.name end)
  ui.title("Installed packages")
  ui.table({
    { title = "PACKAGE", key = "name" },
    { title = "VERSION", key = "version" },
    { title = "KIND", key = "kind" },
  }, rows)
end

local function show_available(source)
  local index, err = source.index()
  if not index then
    ui.print(err, "error")
    return
  end
  local installed = pkg.installed()
  local rows = {}
  for name, entry in pairs(index.packages) do
    local status = "-"
    if installed[name] then
      local order = pkg.compare_versions(entry.version, installed[name].version)
      status = order > 0 and ("update from " .. installed[name].version) or "installed"
    end
    rows[#rows + 1] = {
      name = name,
      version = entry.version,
      kind = entry.kind or (entry.optional and "optional" or "base"),
      status = status,
    }
  end
  table.sort(rows, function(a, b) return a.name < b.name end)
  ui.title("Packages on " .. source.describe())
  ui.table({
    { title = "PACKAGE", key = "name" },
    { title = "VERSION", key = "version" },
    { title = "KIND", key = "kind" },
    { title = "STATUS", key = "status" },
  }, rows, function(row)
    if row.status:find("update") then
      return "warn"
    elseif row.status == "installed" then
      return "ok"
    end
    return "text"
  end)
end

-- In a domain, packages with roles stay open until a domain admin sets them up: say how.
local function hint_role_setup(packages)
  local found, domain = pcall(import, "domain")
  if not (found and domain.is_joined()) then
    return
  end
  local installed = pkg.installed()
  for _, bundle in ipairs(packages) do
    local manifest = bundle.manifest
    local is_new = not (installed[manifest.name] and installed[manifest.name].roles)
    if manifest.roles and #manifest.roles > 0 and is_new then
      ui.print(manifest.name .. " is open to everyone until a domain admin runs", "dim")
      ui.print("'domain setup " .. manifest.name .. "' (after the reboot).", "dim")
    end
  end
end

-- Wait until a requirement is met: a disk event re-checks; s installs anyway, q cancels.
local function wait_for(requirement)
  local requirements = import("requirements")
  ui.print("Waiting... (s: install anyway, q: cancel)", "dim")
  while not requirements.is_met(requirement.name) do
    local event, value = os.pullEvent()
    if event == "char" and value == "q" then
      return false
    elseif event == "char" and value == "s" then
      ui.print("Installing anyway; it waits until this is fixed.", "warn")
      return true
    end
  end
  ui.print("Found.", "ok")
  return true
end

-- What new packages need before they are set up (manifest `requires`).
-- @treturn boolean false when the person cancelled
local function check_requirements(packages)
  local requirements = import("requirements")
  local installed = pkg.installed()
  for _, bundle in ipairs(packages) do
    if not installed[bundle.manifest.name] then
      for _, requirement in ipairs(requirements.missing(bundle.manifest)) do
        ui.print(requirement.message, requirement.wait and "warn" or "dim")
        if requirement.wait and not wait_for(requirement) then
          return false
        end
      end
    end
  end
  return true
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
  if not check_requirements(packages) then
    ui.print("Cancelled.", "warn")
    return
  end
  hint_role_setup(packages)
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

------------------------------------------------------------------------------
-- pkg update (was the separate `update` command)
------------------------------------------------------------------------------

local function confirm(question, default_yes)
  write(question .. (default_yes and " [Y/n] " or " [y/N] "))
  local answer = read():lower()
  if answer == "" then
    return default_yes
  end
  return answer == "y"
end

-- Each package keeps the version of the release it last changed in, so an update
-- compares package by package and downloads only what changed.
local function update(source, options)
  ui.print("Checking " .. source.describe() .. "...", "dim")
  local index, err = source.index()
  if not index then
    ui.print(err, "error")
    return
  end
  local names, select_error = pkg.select(index)
  if not names then
    ui.print(select_error, "error")
    return
  end
  local changes = pkg.changes(index, names)
  if #changes == 0 then
    ui.print("Up to date with release " .. tostring(index.version) .. ".", "ok")
    return
  end
  ui.title("Release " .. tostring(index.version) .. ": " .. #changes .. " package(s) changed")
  local is_downgrade = false
  for _, change in ipairs(changes) do
    local older = change.from and pkg.compare_versions(change.to, change.from) < 0
    is_downgrade = is_downgrade or older
    print(string.format("  %-20s %s -> %s%s", change.name, change.from or "new", change.to,
      older and "  (older)" or ""))
  end
  if options.check_only then
    return
  end
  if not options.assume_yes then
    local question = is_downgrade and "Some are older. Install anyway?" or "Update now?"
    if not confirm(question, not is_downgrade) then
      return
    end
  end
  local wanted = {}
  for _, change in ipairs(changes) do
    wanted[#wanted + 1] = change.name
  end
  local fetched, packages = pkg.fetch(source, show_progress, wanted)
  if not fetched then
    ui.print(packages, "error")
    return
  end
  apply_and_reboot(packages, { force = options.force })
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
local needs_names = command == "install" or command == "remove" or command == "publish"
local is_known = needs_names or command == "list" or command == "update"

if command == "installed" then
  show_installed()
  return
end
if not is_known or (needs_names and #options.names == 0) then
  print_usage()
  return
end
local is_read_only = command == "list" or (command == "update" and options.check_only)
if not is_read_only and not is_admin() then
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
if command == "install" then
  -- The source is picked automatically, so say which one it is.
  ui.print("Using " .. source.describe(), "dim")
end
if command == "list" then
  show_available(source)
elseif command == "install" then
  install(source, options.names, options.force)
else
  update(source, options)
end
