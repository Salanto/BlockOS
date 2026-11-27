-- profile: your roaming profile, kept by the domain controller, on every computer.
--
--   profile                         your apps and roaming settings
--   profile app add|remove <app>    apps opened in tabs when you log in (advanced
--                                   computers; basic ones list them)
--   profile set <key> <value>       a setting that follows you, e.g.
--                                   profile set blockos.logistics.server kitchen
--   profile unset <key>
--   profile keys                    which settings can follow you on this computer
local args = { ... }
local ui = blockos.ui
local config = import("config")
local domain = import("domain")

local function print_usage()
  print("Usage: profile")
  print("       profile app add|remove <app>")
  print("       profile set <key> <value> | unset <key> | keys")
end

local function fail(message)
  ui.print(tostring(message), "error")
end

local function show(profile)
  ui.title("Profile of " .. blockos.user.name)
  local apps = #profile.apps > 0 and table.concat(profile.apps, ", ") or "(none)"
  ui.field("Apps", apps, nil, 9)
  local keys = {}
  for key in pairs(profile.settings) do
    keys[#keys + 1] = key
  end
  table.sort(keys)
  if #keys == 0 then
    ui.field("Settings", "(none)", nil, 9)
  end
  for _, key in ipairs(keys) do
    local note = config.roams(key) and "" or " (not used on this computer)"
    ui.field(key, tostring(profile.settings[key]) .. note, nil, 9)
  end
end

-- "true"/"false" and numbers become what they look like.
local function parse_value(text)
  if text == "true" then
    return true
  elseif text == "false" then
    return false
  end
  return tonumber(text) or text
end

local function save(changes, done)
  local profile, err = domain.profile_set(changes)
  if not profile then
    return fail(err)
  end
  -- This session uses the new values right away; other computers at the next login.
  config.set_session(profile.settings)
  ui.print(done, "ok")
end

local function change_apps(profile, action, app)
  if not app or (action ~= "add" and action ~= "remove") then
    return print_usage()
  end
  local apps = {}
  for _, name in ipairs(profile.apps) do
    if name ~= app then
      apps[#apps + 1] = name
    end
  end
  if action == "add" then
    apps[#apps + 1] = app
    if not shell.resolveProgram(app) then
      ui.print(app .. " is not installed here; it opens where it is.", "dim")
    end
  end
  save({ apps = apps }, action == "add" and (app .. " opens when you log in.")
    or (app .. " no longer opens at login."))
end

local function change_setting(profile, key, value)
  if not key or not key:match("^blockos%.") then
    return fail("Settings are blockos.* keys; see 'profile keys'.")
  end
  local settings = {}
  for name, old in pairs(profile.settings) do
    settings[name] = old
  end
  settings[key] = value
  if value ~= nil and not config.roams(key) then
    ui.print(key .. " does not follow users on this computer (see 'profile keys').", "warn")
  end
  save({ settings = settings }, value == nil and (key .. " removed.") or (key .. " saved."))
end

local function show_keys()
  ui.title("Settings that can follow you")
  local keys = config.roaming_keys()
  if #keys == 0 then
    ui.print("  (none on this computer)", "faint")
  end
  for _, key in ipairs(keys) do
    ui.print("  " .. key)
  end
end

if not (blockos.user and blockos.user.source == "domain") then
  return fail("Log in with a domain account: profiles are kept by the domain.")
end

local command = args[1]
if command == "keys" then
  return show_keys()
end
local profile, err = domain.profile_get()
if not profile then
  return fail(err)
end
if command == nil then
  show(profile)
elseif command == "app" then
  change_apps(profile, args[2], args[3])
elseif command == "set" and args[2] and args[3] then
  change_setting(profile, args[2], parse_value(table.concat(args, " ", 3)))
elseif command == "unset" and args[2] then
  change_setting(profile, args[2], nil)
else
  print_usage()
end
