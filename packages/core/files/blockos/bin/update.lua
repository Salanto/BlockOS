-- update: upgrade BlockOS from the latest GitHub release, a specific tag, or a disk.
--
--   update                 upgrade from the latest release
--   update --tag <tag>     use a specific release (e.g. a prerelease)
--   update --disk          upgrade from a BlockOS disk in an attached drive
--   update --check         only show the installed and available versions
--   update --make-disk     write an install disk to the floppy in an attached drive
--   update -y              do not ask for confirmation
local args = { ... }

local ui = blockos.ui
local pkg = blockos.pkg

local function print_usage()
  print("Usage: update [--tag <tag>] [--disk] [--check] [-y]")
  print("       update --make-disk [--tag <tag>]")
end

local function parse_args()
  local options = {}
  local i = 1
  while i <= #args do
    local flag = args[i]
    if flag == "--tag" then
      options.tag = args[i + 1]
      i = i + 1
    elseif flag == "--disk" then
      options.from_disk = true
    elseif flag == "--make-disk" then
      options.make_disk = true
    elseif flag == "--check" then
      options.check_only = true
    elseif flag == "-y" or flag == "--yes" then
      options.assume_yes = true
    else
      return nil
    end
    i = i + 1
  end
  return options
end

-- Mount path of a disk in an attached drive. With `needs_index`, only a BlockOS disk.
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

local function confirm(question, default_yes)
  write(question .. (default_yes and " [Y/n] " or " [y/N] "))
  local answer = read():lower()
  if answer == "" then
    return default_yes
  end
  return answer == "y"
end

local function make_disk(source)
  local dir = find_disk(false)
  if not dir then
    ui.print("Insert a floppy disk into an attached disk drive.", "error")
    return
  end
  local index, packages = pkg.fetch(source, show_progress)
  if not index then
    ui.print(packages, "error")
    return
  end
  local ok, err = pkg.write_media(dir, index, packages)
  if not ok then
    ui.print(err, "error")
    return
  end
  ui.print("Wrote the BlockOS " .. tostring(index.version) .. " installer to " .. dir, "ok")
end

local function upgrade(source, available, assume_yes)
  if not assume_yes then
    local order = pkg.compare_versions(available, blockos.version)
    local question = "Upgrade now?"
    if order == 0 then
      question = "Already up to date. Reinstall?"
    elseif order < 0 then
      question = "That version is older. Downgrade?"
    end
    if not confirm(question, order > 0) then
      return
    end
  end

  local index, packages = pkg.fetch(source, show_progress)
  if not index then
    ui.print(packages, "error")
    return
  end
  local ok, err = pkg.apply(packages, { progress = show_progress })
  if not ok then
    ui.print("Update failed: " .. err, "error")
    return
  end
  ui.print("Updated to " .. tostring(index.version) .. ". Rebooting...", "ok")
  sleep(2)
  os.reboot()
end

local options = parse_args()
if not options then
  print_usage()
  return
end
if not options.check_only and not (blockos.user and blockos.user.is_admin) then
  ui.print("Only administrators can update.", "error")
  return
end

local source
if options.from_disk then
  local dir = find_disk(true)
  if not dir then
    ui.print("No BlockOS disk found.", "error")
    return
  end
  source = pkg.disk_source(dir)
else
  source = pkg.github_source(options.tag)
end

if options.make_disk then
  make_disk(source)
  return
end

ui.print("Checking " .. source.describe() .. "...", "dim")
local index, err = source.index()
if not index then
  ui.print(err, "error")
  return
end
local available = tostring(index.version)
print("Installed: " .. blockos.version .. "   Available: " .. available)
if not options.check_only then
  upgrade(source, available, options.assume_yes)
end
