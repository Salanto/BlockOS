--- Package storage for the package server, spread over disk drives.
--
-- Every mounted drive is used, including drives on a wired modem network (CC
-- mounts them as /disk2, /disk3, ...), plus the computer's own disk as a last
-- resort. Each package is stored as <root>/blockos-repo/<name>.pkg with a small
-- <name>.meta next to it, so listing packages never has to read whole packages.
-- A drive that disappears just makes its packages unavailable.
--
-- Access rules (/etc/blockos/pkg-server): { [name] = { groups = { ... } } }.
-- Packages without a rule are public.
-- @module repo

local fsx = import("fsx")
local paths = import("paths")
local pkg = import("pkg")
local rpc = import("rpc")

local repo = {}

local REPO_DIR = "blockos-repo"
local ADMINS = "domain-admins"

local root_override = nil

--- Use these directories instead of the mounted drives (tests).
-- @tparam {string...}|nil roots
function repo.set_roots(roots)
  root_override = roots
end

--- Directories packages are stored under: every disk, then the local disk.
-- @treturn {string...}
function repo.roots()
  if root_override then
    return root_override
  end
  local roots = {}
  for _, side in ipairs(peripheral.getNames()) do
    if peripheral.getType(side) == "drive" and disk.hasData(side) then
      roots[#roots + 1] = "/" .. disk.getMountPath(side)
    end
  end
  local local_root = paths.top("var")
  if not fs.exists(local_root) then
    fs.makeDir(local_root)
  end
  roots[#roots + 1] = local_root
  return roots
end

local function repo_dir(root)
  return fs.combine(root, REPO_DIR)
end

--- All stored packages.
-- @treturn table { [name] = { root, version, size, sum, depends, optional, exclusive } }
function repo.scan()
  local found = {}
  for _, root in ipairs(repo.roots()) do
    local dir = repo_dir(root)
    if fs.exists(dir) then
      for _, file in ipairs(fs.list(dir)) do
        local name = file:match("^(.-)%.meta$")
        local meta = name and fsx.read_table(fs.combine(dir, file))
        if meta and not found[name] then
          meta.root = root
          found[name] = meta
        end
      end
    end
  end
  return found
end

local function remove_everywhere(name)
  for _, root in ipairs(repo.roots()) do
    for _, extension in ipairs({ ".pkg", ".meta" }) do
      local path = fs.combine(repo_dir(root), name .. extension)
      if fs.exists(path) then
        fs.delete(path)
      end
    end
  end
end

local function roomiest_root(needed)
  local best, best_free = nil, -1
  for _, root in ipairs(repo.roots()) do
    local free = fs.getFreeSpace(root)
    if free >= needed and free > best_free then
      best, best_free = root, free
    end
  end
  return best
end

--- Store a package (replacing any older copy) on the drive with most free space.
-- @tparam string raw The .pkg file contents.
-- @treturn[1] table Its metadata.
-- @treturn[2] nil
-- @treturn[2] string error message
function repo.store(raw)
  local bundle, err = pkg.decode(raw)
  if not bundle then
    return nil, err
  end
  local manifest = bundle.manifest
  local meta = {
    name = manifest.name,
    version = manifest.version,
    depends = manifest.depends,
    optional = manifest.optional,
    exclusive = manifest.exclusive,
    size = #raw,
    sum = pkg.checksum(raw),
  }
  local meta_text = textutils.serialise(meta)
  remove_everywhere(manifest.name)
  local root = roomiest_root(#raw + #meta_text + 1024)
  if not root then
    return nil, "no drive has room for " .. manifest.name
  end
  local dir = repo_dir(root)
  fsx.write(fs.combine(dir, manifest.name .. ".pkg"), raw)
  fsx.write(fs.combine(dir, manifest.name .. ".meta"), meta_text)
  return meta
end

--- @tparam string name
-- @treturn string|nil The package's bytes.
function repo.read(name)
  local meta = repo.scan()[name]
  if not meta then
    return nil
  end
  return fsx.read_raw(fs.combine(repo_dir(meta.root), name .. ".pkg"))
end

------------------------------------------------------------------------------
-- Access rules
------------------------------------------------------------------------------

local function rules_path()
  return paths.top("etc/blockos/pkg-server")
end

--- @treturn table { [name] = { groups = {...} } }
function repo.rules()
  return fsx.read_table(rules_path()) or {}
end

--- Restrict a package to groups, or make it public again (groups = nil).
-- @tparam string name
-- @tparam {string...}|nil groups
function repo.set_rule(name, groups)
  local rules = repo.rules()
  if groups and #groups > 0 then
    rules[name] = { groups = groups }
  else
    rules[name] = nil
  end
  fsx.write_table(rules_path(), rules)
end

local function in_any_group(user_groups, wanted)
  for _, group in ipairs(user_groups or {}) do
    for _, allowed in ipairs(wanted) do
      if group == allowed then
        return true
      end
    end
  end
  return false
end

------------------------------------------------------------------------------
-- Request handlers (protocol "blockos.pkg")
------------------------------------------------------------------------------

--- @treturn table { [op] = function(request_ctx, args) }
function repo.handlers()
  local handlers = {}

  -- Restricted packages are only listed for users in an allowed group.
  function handlers.index(ctx)
    local rules = repo.rules()
    local user = ctx.token and rpc.require_user(ctx)
    local packages = {}
    for name, meta in pairs(repo.scan()) do
      local rule = rules[name]
      if not rule or (user and in_any_group(user.groups, rule.groups)) then
        meta.root = nil
        packages[name] = meta
      end
    end
    local core = packages.core
    return { version = core and core.version or "?", packages = packages }
  end

  function handlers.fetch(ctx, args)
    local name = type(args) == "table" and args.name
    if type(name) ~= "string" then
      return nil, "which package?"
    end
    local rule = repo.rules()[name]
    if rule then
      local user, err = rpc.require_user(ctx, rule.groups)
      if not user then
        return nil, err
      end
    end
    local raw = repo.read(name)
    if not raw then
      return nil, "no package named " .. name .. " on this server"
    end
    return raw
  end

  function handlers.publish(ctx, args)
    local user, err = rpc.require_user(ctx, { ADMINS })
    if not user then
      return nil, err
    end
    local raw = type(args) == "table" and args.raw
    if type(raw) ~= "string" then
      return nil, "no package given"
    end
    local meta, store_error = repo.store(raw)
    if not meta then
      return nil, store_error
    end
    return { name = meta.name, version = meta.version }
  end

  return handlers
end

return repo
