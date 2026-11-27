--- Package sources: install disks and GitHub releases.
-- (pkg offers these functions too.)
-- @module pkg_sources

local fsx = import("fsx")

local pkg_sources = {}

pkg_sources.RELEASES_URL = "https://github.com/Salanto/BlockOS/releases"

------------------------------------------------------------------------------
-- Sources
--
-- A source has describe(), index() and fetch(name). index() and fetch() return
-- nil, err on failure. Layouts:
--   HTTP (release assets): <base>/index.lua and <base>/<name>.pkg
--   Disk:                  <dir>/index.lua  and <dir>/packages/<name>.pkg
------------------------------------------------------------------------------

--- A source reading from an install disk (or any directory).
-- @tparam string dir
-- @treturn table
function pkg_sources.disk_source(dir)
  local source = {}

  function source.describe()
    return "disk " .. dir
  end

  function source.index()
    local index = fsx.read_table(fs.combine(dir, "index.lua"))
    if not index then
      return nil, "no index.lua on " .. dir
    end
    return index
  end

  function source.fetch(name)
    local raw = fsx.read_raw(fs.combine(dir, "packages/" .. name .. ".pkg"))
    if not raw then
      return nil, "missing " .. name .. ".pkg on " .. dir
    end
    return raw
  end

  return source
end

local function http_get(url)
  if not http then
    return nil, "the HTTP API is disabled on this server"
  end
  local response, err = http.get(url, nil, true)
  if not response then
    return nil, string.format("download failed: %s (%s)", tostring(err), url)
  end
  local body = response.readAll()
  response.close()
  return body
end

--- A source reading GitHub release assets.
--
-- Uses the plain download URLs, not api.github.com, whose 60 requests per hour
-- limit is shared by every computer on the server.
-- @tparam[opt] string tag e.g. "v0.1.0-rc1"; nil for the latest release.
-- @treturn table
function pkg_sources.github_source(tag)
  local base
  if tag then
    base = pkg_sources.RELEASES_URL .. "/download/" .. tag
  else
    base = pkg_sources.RELEASES_URL .. "/latest/download"
  end
  local source = {}

  function source.describe()
    return tag and ("GitHub release " .. tag) or "the latest GitHub release"
  end

  function source.index()
    local raw, err = http_get(base .. "/index.lua")
    if not raw then
      return nil, err
    end
    local index = textutils.unserialise(raw)
    if type(index) ~= "table" then
      return nil, "the release index is unreadable"
    end
    return index
  end

  function source.fetch(name)
    return http_get(base .. "/" .. name .. ".pkg")
  end

  return source
end

return pkg_sources
