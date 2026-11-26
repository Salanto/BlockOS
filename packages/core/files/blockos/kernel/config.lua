--- Configuration, built on CC's `settings` API.
--
-- Defaults live in code (`config.define`), so upgrades can add new keys without
-- touching user files. Values are stored in CC's normal /.settings, so the
-- built-in `set` program works on BlockOS keys too.
-- @module config

local config = {}

--- Declare a setting and its default.
-- @tparam string key e.g. "blockos.log.level"
-- @tparam table options { description, default, type } as for settings.define.
function config.define(key, options)
  settings.define(key, options)
end

--- Read a setting.
-- @tparam string key
-- @param[opt] fallback Returned when the setting has no value and no default.
function config.get(key, fallback)
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

config.define("blockos.services.disabled", {
  description = "Names of BlockOS services that should not start.",
  default = {},
  type = "table",
})

return config
