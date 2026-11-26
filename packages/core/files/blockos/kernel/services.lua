--- Service manager.
--
-- Each file in <root>/services/*.lua returns a service definition:
--
--     return {
--       name = "net",
--       description = "Modems, hostname and peer discovery",
--       after = { "other" },          -- start after these services, if present
--       restart = "on-failure",       -- or "always" / "never"
--       condition = function()        -- optional; false marks it "n/a" here
--         return true
--       end,
--       run = function(ctx) ... end,  -- ctx = { name, log, config }
--     }
--
-- Services run in the scheduler, never receive `terminate`, and must not draw
-- to the terminal: print, write and printError are redirected to the log.
-- @module services

local config = import("config")
local log = import("log")

local services = {}

local CRASH_WINDOW_SECONDS = 120
local CRASH_LIMIT = 5

local scheduler = nil
local definitions = {}
local status = {}
local start_order = {}
local restart_timers = {}

-- An environment where terminal output goes to the log instead.
local function service_environment(name)
  local logger = log.logger(name)

  local function join(...)
    local parts = table.pack(...)
    for i = 1, parts.n do
      parts[i] = tostring(parts[i])
    end
    return table.concat(parts, " ", 1, parts.n)
  end

  local overrides = {
    print = function(...) logger.info(join(...)) end,
    write = function(text) logger.info(tostring(text)) end,
    printError = function(...) logger.error(join(...)) end,
  }
  return setmetatable(overrides, { __index = _G })
end

local function new_status()
  return { state = "stopped", crash_times = {} }
end

local function load_definition(path, name)
  local chunk, load_error = loadfile(path, nil, service_environment(name))
  if not chunk then
    return nil, load_error
  end
  local ok, definition = pcall(chunk)
  if not ok then
    return nil, definition
  end
  if type(definition) ~= "table" or type(definition.run) ~= "function" then
    return nil, "service file must return a table with a run function"
  end
  definition.name = definition.name or name
  definition.restart = definition.restart or "on-failure"
  return definition
end

--- Compute the start order from `after` (depth-first topological sort).
-- Unknown names in `after` are ignored; cycles are logged and broken.
-- @treturn {string...} Service names in start order.
function services.compute_order()
  local names = {}
  for name in pairs(definitions) do
    names[#names + 1] = name
  end
  table.sort(names)

  start_order = {}
  local visit_state = {}

  local function visit(name)
    if visit_state[name] == "done" then
      return
    end
    if visit_state[name] == "visiting" then
      log.warn("services", "dependency cycle involving %s", name)
      return
    end
    visit_state[name] = "visiting"
    for _, dependency in ipairs(definitions[name].after or {}) do
      if definitions[dependency] then
        visit(dependency)
      end
    end
    visit_state[name] = "done"
    start_order[#start_order + 1] = name
  end

  for _, name in ipairs(names) do
    visit(name)
  end
  return start_order
end

--- Load every service definition in a directory, replacing any loaded before.
-- @tparam string dir
function services.load(dir)
  definitions = {}
  status = {}
  if fs.exists(dir) then
    for _, file in ipairs(fs.list(dir)) do
      local name = file:match("^(.-)%.lua$")
      if name then
        local definition, err = load_definition(fs.combine(dir, file), name)
        if definition then
          definitions[definition.name] = definition
          status[definition.name] = new_status()
        else
          log.error("services", "invalid service %s: %s", file, tostring(err))
          status[name] = { state = "failed", crash_times = {}, last_error = tostring(err) }
        end
      end
    end
  end
  services.compute_order()
end

--- Add one service definition (used by tests).
-- @tparam table definition
function services.register(definition)
  definition.restart = definition.restart or "on-failure"
  definitions[definition.name] = definition
  status[definition.name] = status[definition.name] or new_status()
  services.compute_order()
end

--- Connect the manager to a scheduler. Must be called before starting services.
-- @tparam Scheduler new_scheduler
function services.init(new_scheduler)
  scheduler = new_scheduler
  restart_timers = {}
  scheduler:add_hook(function(event, timer_id)
    local name = event == "timer" and restart_timers[timer_id]
    if not name then
      return
    end
    restart_timers[timer_id] = nil
    if status[name] and status[name].state == "restarting" then
      services.start(name)
    end
  end)
end

local function is_disabled(name)
  for _, disabled in ipairs(config.get("blockos.services.disabled", {})) do
    if disabled == name then
      return true
    end
  end
  return false
end

-- Crashes within the window, including this one.
local function record_crash(service_status)
  local now = os.clock()
  local recent = {}
  for _, time in ipairs(service_status.crash_times) do
    if now - time < CRASH_WINDOW_SECONDS then
      recent[#recent + 1] = time
    end
  end
  recent[#recent + 1] = now
  service_status.crash_times = recent
  return #recent
end

local function on_service_exit(name, ok, err)
  local service_status = status[name]
  local definition = definitions[name]

  if ok then
    log.info("services", "%s exited", name)
    service_status.state = "stopped"
    if definition.restart ~= "always" then
      return
    end
  else
    log.error("services", "%s crashed: %s", name, tostring(err))
    service_status.last_error = tostring(err)
    if definition.restart == "never" then
      service_status.state = "crashed"
      return
    end
  end

  local crash_count = record_crash(service_status)
  if crash_count >= CRASH_LIMIT then
    service_status.state = "failed"
    log.error("services", "%s stopped %d times in %ds; giving up",
      name, crash_count, CRASH_WINDOW_SECONDS)
    return
  end

  local delay_seconds = 2 ^ (crash_count - 1)
  service_status.state = "restarting"
  restart_timers[os.startTimer(delay_seconds)] = name
end

--- Start a service.
-- @tparam string name
-- @treturn[1] true
-- @treturn[2] nil
-- @treturn[2] string why it did not start
function services.start(name)
  local definition = definitions[name]
  if not definition then
    return nil, "no such service"
  end
  if scheduler:is_running(name) then
    return nil, "already running"
  end

  local service_status = status[name]
  if definition.condition then
    local ok, applies = pcall(definition.condition)
    if not ok or not applies then
      service_status.state = "n/a"
      return nil, "not applicable on this device"
    end
  end

  service_status.state = "running"
  local context = { name = name, log = log.logger(name), config = config }
  scheduler:spawn(name,
    function() definition.run(context) end,
    function(ok, err) on_service_exit(name, ok, err) end)

  if service_status.state == "running" then
    log.info("services", "started %s", name)
  end
  return true
end

--- Stop a service (and cancel a pending restart).
-- @tparam string name
-- @treturn[1] true
-- @treturn[2] nil
-- @treturn[2] string error message
function services.stop(name)
  local service_status = status[name]
  if not service_status then
    return nil, "no such service"
  end
  for timer_id, timer_name in pairs(restart_timers) do
    if timer_name == name then
      restart_timers[timer_id] = nil
    end
  end
  scheduler:kill(name)
  service_status.state = "stopped"
  log.info("services", "stopped %s", name)
  return true
end

--- Stop and start a service, clearing its crash history.
-- @tparam string name
function services.restart(name)
  local ok, err = services.stop(name)
  if not ok then
    return nil, err
  end
  status[name].crash_times = {}
  return services.start(name)
end

--- Start every service that is not disabled, in dependency order.
function services.start_all()
  for _, name in ipairs(start_order) do
    if is_disabled(name) then
      status[name].state = "disabled"
    else
      services.start(name)
    end
  end
end

--- @treturn {table...} { name, description, state, last_error } in start order.
function services.list()
  local listed = {}
  local result = {}
  for _, name in ipairs(start_order) do
    local service_status = status[name]
    result[#result + 1] = {
      name = name,
      description = definitions[name].description,
      state = service_status.state,
      last_error = service_status.last_error,
    }
    listed[name] = true
  end
  -- Services whose file failed to load have a status but no definition.
  for name, service_status in pairs(status) do
    if not listed[name] then
      result[#result + 1] = {
        name = name,
        state = service_status.state,
        last_error = service_status.last_error,
      }
    end
  end
  return result
end

--- @tparam string name
-- @treturn string|nil The service's state.
function services.state(name)
  return status[name] and status[name].state
end

--- @treturn {string...} Names of running services.
function services.running()
  local names = {}
  for _, name in ipairs(start_order) do
    if status[name].state == "running" then
      names[#names + 1] = name
    end
  end
  return names
end

return services
