--- Events that a blocking call skipped, kept for the coroutine that was waiting.
--
-- A call that waits for one particular event (rpc waiting for its answer) has to pull
-- every event to find it. Anything else that arrives meanwhile (the loop's own timer,
-- an alert, a key) would be gone for that coroutine. Re-queueing it is no fix: every
-- other coroutine already saw it and would see it twice. So the waiting call keeps the
-- skipped events here (events.keep), and the coroutine's loop pulls with events.pull
-- instead of os.pullEvent: kept events come first, in order.
-- @module events

local events = {}

--- Most events kept per coroutine (the oldest go first).
events.MAX_KEPT = 64

-- [coroutine] = { packed events }; weak keys, so a finished coroutine's are dropped.
local kept = setmetatable({}, { __mode = "k" })

--- Keep an event the current coroutine pulled but did not want.
-- @param ... The event, as os.pullEvent returned it.
function events.keep(...)
  local routine = coroutine.running()
  local list = kept[routine] or {}
  list[#list + 1] = table.pack(...)
  if #list > events.MAX_KEPT then
    table.remove(list, 1)
  end
  kept[routine] = list
end

--- Like os.pullEvent, but kept events come first.
-- @tparam[opt] string filter Only this event (kept ones that do not match are dropped,
--   as os.pullEvent drops them).
-- @return The event.
function events.pull(filter)
  local list = kept[coroutine.running()]
  while list and #list > 0 do
    local event = table.remove(list, 1)
    if filter == nil or event[1] == filter then
      return table.unpack(event, 1, event.n)
    end
  end
  return os.pullEvent(filter)
end

--- How many events are kept for the current coroutine (tests).
function events.count()
  local list = kept[coroutine.running()]
  return list and #list or 0
end

return events
