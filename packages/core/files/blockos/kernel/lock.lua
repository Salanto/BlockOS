--- A lock for work that must not overlap, between coroutines of one computer (rpc
-- handlers, a service's loop): exclusive (one at a time, nobody shared) or shared
-- (many at once, while nobody holds it exclusively). Waiting is by event, not polling.
-- @module lock

local lock = {}

lock.EVENT = "blockos_lock_released"

local next_id = 0

--- Make a lock.
-- @treturn table { exclusive(fn, ...), shared(fn, ...), try_exclusive(fn, ...),
--   is_busy() }
function lock.new()
  next_id = next_id + 1
  local self = { id = next_id, readers = 0, writer = false }

  local function release()
    os.queueEvent(lock.EVENT, self.id)
  end

  -- Wait until `can()` holds, at most `timeout` seconds (nil: for ever).
  local function wait_until(can, timeout)
    local timer = timeout and os.startTimer(timeout)
    while not can() do
      local event, value = os.pullEvent()
      if event == "timer" and value == timer then
        return false
      end
    end
    if timer then
      os.cancelTimer(timer)
    end
    return true
  end

  local function run(fn, ...)
    return table.pack(pcall(fn, ...))
  end

  local function finish(results)
    if not results[1] then
      error(results[2], 0)
    end
    return table.unpack(results, 2, results.n)
  end

  function self.is_busy()
    return self.writer or self.readers > 0
  end

  --- Run fn alone (waits for everyone else).
  function self.exclusive(fn, ...)
    wait_until(function() return not self.is_busy() end)
    self.writer = true
    local results = run(fn, ...)
    self.writer = false
    release()
    return finish(results)
  end

  --- Run fn only if nobody holds the lock right now.
  -- @return What fn returns, or nil and "busy".
  function self.try_exclusive(fn, ...)
    if self.is_busy() then
      return nil, "busy"
    end
    return self.exclusive(fn, ...)
  end

  --- Run fn while nobody holds the lock exclusively (others may share it).
  -- @tparam[opt] number timeout Seconds to wait; nil waits for ever.
  -- @return What fn returns, or nil and "busy" after the timeout.
  function self.shared(fn, timeout, ...)
    if not wait_until(function() return not self.writer end, timeout) then
      return nil, "busy"
    end
    self.readers = self.readers + 1
    local results = run(fn, ...)
    self.readers = self.readers - 1
    release()
    return finish(results)
  end

  return self
end

return lock
