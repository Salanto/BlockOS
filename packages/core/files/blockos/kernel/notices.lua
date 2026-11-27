--- Notices: one-line messages shown on the welcome screen at login (and by remote
-- admin), e.g. "2 item(s) low" or "3 new messages". Each package owns its keys
-- ("logistics", "mail", ...) and sets or clears only those.
--
-- A notice set with a level ("warn" or "error") is a problem: something on this
-- computer needs fixing (a failed service, a missing disk). Problems also go out as
-- alerts: a joined computer reports them to the domain controller, which raises them
-- with the alert hub (see the alerts module) and says when they are fixed. Messages
-- for the user (new mail, an update waiting) have no level.
-- @module notices

local notices = {}

notices.LEVELS = { warn = true, error = true }
--- Queued whenever the problems change, so a reporter can send them at once.
notices.PROBLEMS_EVENT = "blockos_problems"

local function store()
  if not blockos then
    return {}, {}
  end
  blockos.notices = blockos.notices or {}
  blockos.notice_levels = blockos.notice_levels or {}
  return blockos.notices, blockos.notice_levels
end

--- Show a notice under a key, or clear it (text nil).
-- @tparam string key
-- @tparam[opt] string text
-- @tparam[opt] string level "warn" or "error" for a problem (see the module comment).
function notices.set(key, text, level)
  local texts, levels = store()
  if level ~= nil and not notices.LEVELS[level] then
    error("notice levels are warn and error, not " .. tostring(level), 2)
  end
  local was_problem = levels[key] ~= nil
  local changed = texts[key] ~= text or levels[key] ~= level
  texts[key] = text
  levels[key] = text and level or nil
  if blockos and changed and (was_problem or levels[key]) then
    os.queueEvent(notices.PROBLEMS_EVENT)
  end
end

--- Clear a notice.
-- @tparam string key
function notices.clear(key)
  notices.set(key, nil)
end

--- Every notice, sorted.
-- @treturn {string...}
function notices.list()
  local list = {}
  for _, text in pairs(store()) do
    list[#list + 1] = text
  end
  table.sort(list)
  return list
end

--- The notices that are problems, sorted by key.
-- @treturn {table...} { key, text, level }
function notices.problems()
  local texts, levels = store()
  local list = {}
  for key, level in pairs(levels) do
    list[#list + 1] = { key = key, text = texts[key], level = level }
  end
  table.sort(list, function(a, b) return a.key < b.key end)
  return list
end

return notices
