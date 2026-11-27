--- Notices: one-line messages shown on the welcome screen at login (and by remote
-- admin), e.g. "2 item(s) low" or "3 new messages". Each package owns its keys
-- ("logistics", "mail", ...) and sets or clears only those.
-- @module notices

local notices = {}

local function store()
  if not blockos then
    return {}
  end
  blockos.notices = blockos.notices or {}
  return blockos.notices
end

--- Show a notice under a key, or clear it (text nil).
-- @tparam string key
-- @tparam[opt] string text
function notices.set(key, text)
  store()[key] = text
end

--- Clear a notice.
-- @tparam string key
function notices.clear(key)
  store()[key] = nil
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

return notices
