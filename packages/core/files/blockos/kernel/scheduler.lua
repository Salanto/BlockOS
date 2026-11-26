--- Coroutine scheduler for background services.
--
-- Works like CC's `parallel`, except that:
--
-- * tasks can be added and removed while it runs,
-- * a crashing task never takes the others down (errors, including
--   "Too long without yielding", are returned from coroutine.resume and passed
--   to the task's exit callback instead of being re-thrown),
-- * `terminate` is never delivered, so Ctrl+T cannot kill services.
--
-- Each task's os.pullEvent filter is respected, which turtle movement and
-- rednet rely on.
-- @module scheduler

local Scheduler = {}
Scheduler.__index = Scheduler

--- Create an empty scheduler.
-- @treturn Scheduler
local function new()
  local self = setmetatable({}, Scheduler)
  self.tasks = {}
  self.hooks = {}
  return self
end

local function finish(self, task, ok, err)
  if self.tasks[task.name] == task then
    self.tasks[task.name] = nil
  end
  task.is_dead = true
  if task.on_exit then
    task.on_exit(ok, err)
  end
end

-- Resume a task with an event and record what it waits for next.
local function resume(self, task, ...)
  local ok, filter_or_error = coroutine.resume(task.coroutine, ...)
  if not ok then
    finish(self, task, false, filter_or_error)
  elseif coroutine.status(task.coroutine) == "dead" then
    finish(self, task, true)
  else
    task.filter = filter_or_error
  end
end

--- Start a task. It runs immediately until its first yield.
-- @tparam string name Unique task name.
-- @tparam function fn The task body.
-- @tparam[opt] function on_exit Called as on_exit(ok, err) when the task
--   returns or crashes (not when it is killed).
function Scheduler:spawn(name, fn, on_exit)
  if self.tasks[name] then
    error("task already running: " .. name, 2)
  end
  local task = { name = name, coroutine = coroutine.create(fn), on_exit = on_exit }
  self.tasks[name] = task
  resume(self, task)
end

--- Stop a task without calling its exit callback.
-- @tparam string name
-- @treturn boolean False if no such task was running.
function Scheduler:kill(name)
  local task = self.tasks[name]
  if not task then
    return false
  end
  self.tasks[name] = nil
  task.is_dead = true
  return true
end

--- @tparam string name
-- @treturn boolean
function Scheduler:is_running(name)
  return self.tasks[name] ~= nil
end

--- Register a function that sees every event before the tasks do.
-- @tparam function hook Called as hook(event_name, ...).
function Scheduler:add_hook(hook)
  self.hooks[#self.hooks + 1] = hook
end

--- Deliver one event to every task waiting for it.
-- @tparam table event A packed event (table.pack(os.pullEventRaw())).
function Scheduler:dispatch(event)
  if event[1] == "terminate" then
    return
  end
  for _, hook in ipairs(self.hooks) do
    hook(table.unpack(event, 1, event.n))
  end

  -- Copy first: tasks may start or stop other tasks while we iterate.
  local waiting = {}
  for _, task in pairs(self.tasks) do
    waiting[#waiting + 1] = task
  end
  for _, task in ipairs(waiting) do
    local wants_event = task.filter == nil or task.filter == event[1]
    if not task.is_dead and wants_event then
      resume(self, task, table.unpack(event, 1, event.n))
    end
  end
end

--- Pull and dispatch events forever.
function Scheduler:run()
  while true do
    self:dispatch(table.pack(os.pullEventRaw()))
  end
end

return { new = new }
