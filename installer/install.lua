-- BlockOS online installer. Run on a computer or turtle with:
--
--   wget run https://github.com/Salanto/BlockOS/releases/latest/download/install.lua
--
-- Options:
--   --tag <tag>   install a specific release (for example a prerelease)
--   --force       reinstall over an existing installation

local RELEASES_URL = "https://github.com/Salanto/BlockOS/releases/"

local function parse_args(args)
  local options = {}
  for i = 1, #args do
    if args[i] == "--tag" then
      options.tag = args[i + 1]
    elseif args[i] == "--force" then
      options.force = true
    end
  end
  return options
end

local function download(url)
  local response, err = http.get(url, nil, true)
  if not response then
    error("download failed: " .. tostring(err) .. " (" .. url .. ")", 0)
  end
  local body = response.readAll()
  response.close()
  return body
end

-- Load kernel modules straight out of the downloaded core package. The same
-- bootstrap exists in the disk installer: nothing is installed yet to share.
local function make_import(core)
  local loaded = {}
  local function import(name)
    if loaded[name] then
      return loaded[name]
    end
    local source = core.files["blockos/kernel/" .. name .. ".lua"]
    if not source then
      error("module not found: " .. name, 2)
    end
    local env = setmetatable({ import = import }, { __index = _G })
    loaded[name] = assert(load(source, "@" .. name, "t", env))()
    return loaded[name]
  end
  return import
end

local options = parse_args({ ... })

if not http then
  printError("The HTTP API is disabled on this server. Install from a BlockOS disk instead.")
  return
end

local base_url = RELEASES_URL .. (options.tag and ("download/" .. options.tag) or "latest/download")
print("Downloading BlockOS core...")
-- Packages are compressed; the release ships the decompressor next to them.
local lz = assert(load(download(base_url .. "/lz.lua"), "@lz.lua", "t", _ENV))()
local core = textutils.unserialise(lz.unpack(download(base_url .. "/core.pkg")) or "")
if type(core) ~= "table" or type(core.files) ~= "table" then
  printError("The downloaded core package is unreadable.")
  return
end

local import = make_import(core)
local auth = import("auth")
local pkg = import("pkg")
local setup = import("setup")
local ui = import("ui")

if pkg.is_installed() and not options.force then
  ui.print("BlockOS " .. tostring(pkg.installed_version()) .. " is already installed.", "warn")
  print("Use 'update' to upgrade, or run this installer with --force to reinstall.")
  return
end

local function show_progress(message)
  ui.print(message, "dim")
end

local index, packages = pkg.fetch(pkg.github_source(options.tag), show_progress)
if not index then
  ui.print("Error: " .. tostring(packages), "error")
  return
end

local ok, err = pkg.apply(packages, { progress = show_progress })
if not ok then
  ui.print("Error: " .. err, "error")
  return
end

local note = pkg.install_loader(core.files["blockos/loader.lua"])
if note then
  ui.print(note, "warn")
end
if not auth.has_users() then
  setup.create_admin()
end

ui.print("BlockOS " .. tostring(index.version) .. " is installed. Rebooting...", "ok")
sleep(2)
os.reboot()
