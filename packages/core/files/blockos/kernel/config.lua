--- Configuration, built on CC's `settings` API.
--
-- Defaults live in code (`config.define`), so upgrades can add new keys without
-- touching user files. Values are stored in CC's normal /.settings, so the
-- built-in `set` program works on BlockOS keys too.
--
-- Roaming settings (defined with `roams = true`, e.g. which logistics controller to
-- use) can follow a domain user: their profile's values apply for the session only
-- (config.set_session) and are never written to this computer's settings.
-- @module config

local config = {}

local roaming = {} -- [key] = true for settings that may follow a user
local session_values = {} -- the logged-in user's roaming values

--- Declare a setting and its default.
-- @tparam string key e.g. "blockos.log.level"
-- @tparam table options { description, default, type, roams? } as for
--   settings.define; roams = true lets a user's profile set it for their session.
function config.define(key, options)
  if options.roams then
    roaming[key] = true
    local plain = {}
    for name, value in pairs(options) do
      if name ~= "roams" then
        plain[name] = value
      end
    end
    options = plain
  end
  settings.define(key, options)
end

--- May a user's profile set this key?
-- @tparam string key
-- @treturn boolean
function config.roams(key)
  return roaming[key] == true
end

--- The roaming keys defined on this computer, sorted.
-- @treturn {string...}
function config.roaming_keys()
  local keys = {}
  for key in pairs(roaming) do
    keys[#keys + 1] = key
  end
  table.sort(keys)
  return keys
end

--- Use a user's roaming values until the next call (nil at logout). Only keys defined
-- as roaming take effect, also ones defined after this call.
-- @tparam[opt] table values [key] = value
function config.set_session(values)
  session_values = values or {}
end

--- Read a setting.
-- @tparam string key
-- @param[opt] fallback Returned when the setting has no value and no default.
function config.get(key, fallback)
  if roaming[key] and session_values[key] ~= nil then
    return session_values[key]
  end
  local value = settings.get(key)
  if value == nil then
    return fallback
  end
  return value
end

--- Change a setting and save it. Setting nil restores the default.
-- @tparam string key
-- @param value
function config.set(key, value)
  if value == nil then
    settings.unset(key)
  else
    settings.set(key, value)
  end
  settings.save()
end

config.define("blockos.log.level", {
  description = "BlockOS log level: debug, info, warn or error.",
  default = "info",
  type = "string",
})

config.define("blockos.log.max_size", {
  description = "Bytes at which the BlockOS log is rotated (it keeps one old copy).",
  default = 8 * 1024,
  type = "number",
})

config.define("blockos.autologin", {
  description = "Local user logged in automatically at boot (farm computers, displays, turtles).",
  type = "string",
})

config.define("blockos.motd", {
  description = "Message of the day, shown on the login screen.",
  type = "string",
})

config.define("blockos.services.disabled", {
  description = "Names of BlockOS services that should not start.",
  default = {},
  type = "table",
})

return config
