-- pkgserver: manage the packages this computer serves.
--
--   pkgserver status                      drives, free space and packages
--   pkgserver import --disk | --tag <tag> | --latest
--   pkgserver allow <name> <group...>     restrict a package to groups
--   pkgserver public <name>               make a package public again
local args = { ... }
local ui = blockos.ui
local pkg = blockos.pkg
local repo = import("repo")

local function print_usage()
  print("Usage: pkgserver status")
  print("       pkgserver import --disk | --tag <tag> | --latest")
  print("       pkgserver allow <name> <group...> | public <name>")
end

local function is_admin()
  if blockos.user and blockos.user.is_admin then
    return true
  end
  ui.print("Only administrators can change the package server.", "error")
  return false
end

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

local function show_status()
  local drives = {}
  for _, root in ipairs(repo.roots()) do
    drives[#drives + 1] = { root = root, free = fs.getFreeSpace(root) .. " bytes" }
  end
  ui.title("Drives")
  ui.table({ { title = "DRIVE", key = "root" }, { title = "FREE", key = "free" } }, drives)

  local rules = repo.rules()
  local packages = {}
  for name, meta in pairs(repo.scan()) do
    local rule = rules[name]
    packages[#packages + 1] = {
      name = name,
      version = meta.version,
      drive = meta.root,
      access = rule and table.concat(rule.groups, ", ") or "public",
    }
  end
  table.sort(packages, function(a, b) return a.name < b.name end)
  print()
  ui.title("Packages")
  ui.table({
    { title = "PACKAGE", key = "name" },
    { title = "VERSION", key = "version" },
    { title = "DRIVE", key = "drive" },
    { title = "ACCESS", key = "access" },
  }, packages, function(row) return row.access == "public" and "text" or "warn" end)
end

local function import_packages(flag, tag)
  local source
  if flag == "--disk" then
    local dir = find_package_disk()
    if not dir then
      ui.print("No package disk found in an attached drive.", "error")
      return
    end
    source = pkg.disk_source(dir)
  elseif flag == "--tag" and tag then
    source = pkg.github_source(tag)
  elseif flag == "--latest" then
    source = pkg.github_source()
  else
    print_usage()
    return
  end

  local index, err = source.index()
  if not index then
    ui.print(err, "error")
    return
  end
  local names = {}
  for name in pairs(index.packages) do
    names[#names + 1] = name
  end
  table.sort(names)
  local fetched, packages = pkg.fetch(source, function(message) ui.print(message, "dim") end, names)
  if not fetched then
    ui.print(packages, "error")
    return
  end
  for _, bundle in ipairs(packages) do
    local meta, store_error = repo.store(bundle.raw)
    if meta then
      ui.print("Stored " .. meta.name .. " " .. meta.version, "ok")
    else
      ui.print(bundle.manifest.name .. ": " .. store_error, "error")
    end
  end
end

local command = args[1]
if command == "status" or command == nil then
  show_status()
elseif not is_admin() then
  return
elseif command == "import" then
  import_packages(args[2], args[3])
elseif command == "allow" and args[3] then
  local groups = { table.unpack(args, 3) }
  repo.set_rule(args[2], groups)
  ui.print(args[2] .. " is now limited to: " .. table.concat(groups, ", "), "ok")
elseif command == "public" and args[2] then
  repo.set_rule(args[2], nil)
  ui.print(args[2] .. " is now public.", "ok")
else
  print_usage()
end
