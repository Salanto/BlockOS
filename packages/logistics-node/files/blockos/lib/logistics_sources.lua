--- Storage sources for logistics nodes.
--
-- Every file in <root>/lib/storage_sources/ is a source. Packages install into
-- the shared /blockos/lib, so a package that adds a new kind of storage (for
-- example an ME bridge) only has to ship one more file there.
--
-- A source returns:
--   kind                  short name, e.g. "inventory"
--   describe()            text for people
--   detect()              -> list of handles (e.g. peripheral names)
--   read(handle)          -> [item] = { count, label }
-- @module logistics_sources

local logistics_sources = {}

local SOURCE_DIR = "lib/storage_sources"

--- Load every source module.
-- @tparam[opt] string root System tree (default blockos.root).
-- @tparam[opt] function loader Module loader (default import; tests pass their own).
-- @treturn {table...}
function logistics_sources.load(root, loader)
  loader = loader or import
  root = root or (blockos and blockos.root) or "/blockos"
  local dir = fs.combine(root, SOURCE_DIR)
  local sources = {}
  if not fs.isDir(dir) then
    return sources
  end
  local names = fs.list(dir)
  table.sort(names)
  for _, file in ipairs(names) do
    local name = file:match("^(.-)%.lua$")
    if name then
      local ok, source = pcall(loader, "storage_sources/" .. name)
      if ok and type(source) == "table" and type(source.read) == "function" then
        sources[#sources + 1] = source
      end
    end
  end
  return sources
end

--- Read and add up every item from every source.
-- Only blocks whose role is "storage" are read and counted; inputs, outputs
-- and ignored blocks are listed but not read (their items are in transit,
-- already taken, or not ours). A handle that fails (a chest broken mid-read)
-- is skipped, not an error; it is listed in the failures so the caller can
-- log it.
-- @tparam {table...} sources
-- @tparam[opt] function role_of function(handle, source) -> role; default: all storage
-- @treturn table [item] = { count, label }
-- @treturn number How many storage blocks were read.
-- @treturn {table...} failures: { handle, error } per block that could not be read
-- @treturn {table...} inventories: { handle, role, source, items?, fill? } per
--   block found (items only for storage blocks; fill { used, size } when the
--   source reports it, read here so screens never have to ask the blocks)
function logistics_sources.read_all(sources, role_of)
  local totals = {}
  local blocks = 0
  local failures = {}
  local inventories = {}
  for _, source in ipairs(sources) do
    for _, handle in ipairs(source.detect()) do
      local role = role_of and role_of(handle, source) or "storage"
      local inventory = { handle = handle, role = role, source = source }
      inventories[#inventories + 1] = inventory
      local is_transit = role == "input" or role == "output" or role == "port"
        or role == "machine" or role == "recycle"
      if is_transit and type(source.fill) == "function" then
        local ok, fill = pcall(source.fill, handle)
        inventory.fill = ok and fill or nil
      elseif role == "storage" then
        local ok, items, fill = pcall(source.read, handle)
        if not ok or type(items) ~= "table" then
          failures[#failures + 1] = {
            handle = tostring(handle),
            error = ok and "the source returned no item list" or tostring(items),
          }
        else
          blocks = blocks + 1
          inventory.items = items
          inventory.fill = fill
          for item, found in pairs(items) do
            local total = totals[item] or { count = 0, label = found.label }
            total.count = total.count + found.count
            total.label = total.label or found.label
            totals[item] = total
          end
        end
      end
    end
  end
  return totals, blocks, failures, inventories
end

return logistics_sources
