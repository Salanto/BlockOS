--- Central table of every persistent path BlockOS uses.
--
-- Everything goes through here so tests and installers can redirect the whole
-- system into a sandbox directory by setting `paths.prefix`.
-- @module paths

local paths = {}

--- Directory prepended to every path ("" on a real installation).
paths.prefix = ""

local function under_prefix(path)
  return paths.prefix .. path
end

--- @treturn string The installed system tree.
function paths.root()
  return under_prefix("/blockos")
end

--- @treturn string Where a new version is staged during an upgrade.
function paths.staging()
  return under_prefix("/blockos.new")
end

--- @treturn string The previous version, kept for rollback.
function paths.previous()
  return under_prefix("/blockos.old")
end

--- @treturn string The local account database.
function paths.passwd()
  return under_prefix("/etc/blockos/passwd")
end

--- @treturn string Marker written while an upgrade or rollback swaps directories.
function paths.upgrade_state()
  return under_prefix("/etc/blockos/upgrade.state")
end

--- @treturn string Counter of boots that did not reach the login screen.
function paths.bootcount()
  return under_prefix("/etc/blockos/bootcount")
end

--- @treturn string The loader, run by CraftOS on boot.
function paths.startup()
  return under_prefix("/startup.lua")
end

--- @treturn string A `startup` directory/file from another OS, if any.
function paths.startup_dir()
  return under_prefix("/startup")
end

--- @treturn string Where a previous startup program is backed up to.
function paths.startup_backup()
  return under_prefix("/etc/blockos/startup.bak")
end

--- @treturn string The system log.
function paths.log()
  return under_prefix("/var/log/blockos.log")
end

--- Resolve a path relative to the computer root.
-- @tparam string relative e.g. "etc/blockos/motd"
-- @treturn string
function paths.top(relative)
  return under_prefix("/" .. relative)
end

return paths
