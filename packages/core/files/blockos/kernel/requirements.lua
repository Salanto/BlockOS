--- What a package needs before it can be set up (manifest field `requires`).
--
-- A manifest lists names from requirements.CHECKS, e.g. `requires = { "disk", "domain" }`.
-- `pkg install` checks them for packages that are new on this computer: a missing "disk"
-- waits for a floppy to be put in (the person can skip or cancel), a missing "domain" only
-- warns (dcpromo or domain join may follow after the reboot). Installs without anyone at
-- the keyboard (computer roles) skip the checks; the package's service waits instead.
-- @module requirements

local requirements = {}

--- Hardware access (tests replace these).
requirements.env = {
  has_disk = function()
    return import("diskstore").has_disk()
  end,
  is_joined = function()
    local found, domain = pcall(import, "domain")
    return found and domain.is_joined() or false
  end,
}

--- The known requirements: what to check, and what to tell the person.
-- `wait` = true means pkg install waits for it (a disk can be put in right away).
requirements.CHECKS = {
  disk = {
    check = function() return requirements.env.has_disk() end,
    wait = true,
    message = "keeps its data on floppy disks, not on this computer. Attach a disk drive "
      .. "(next to it or on a wired modem) and put a floppy disk in it.",
  },
  domain = {
    check = function() return requirements.env.is_joined() end,
    wait = false,
    message = "needs a domain. Join one ('domain join <name>') or run dcpromo after the "
      .. "reboot; until then it waits.",
  },
}

--- The requirements of a manifest that are not met right now.
-- @tparam table manifest
-- @treturn {table...} { name, message, wait } per missing requirement, in manifest order
function requirements.missing(manifest)
  local list = {}
  for _, name in ipairs(manifest.requires or {}) do
    local known = requirements.CHECKS[name]
    if known and not known.check() then
      list[#list + 1] = { name = name, message = manifest.name .. " " .. known.message,
        wait = known.wait }
    end
  end
  return list
end

--- Is a requirement met right now?
-- @tparam string name
-- @treturn boolean
function requirements.is_met(name)
  local known = requirements.CHECKS[name]
  return known == nil or known.check()
end

return requirements
