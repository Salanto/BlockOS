--- Full-screen tools with tabs (dsa, the logistics tool): one shared loop, so every
-- tool has the same keys.
--
--   1-9 / Tab  switch tab     Up/Down/PgUp/PgDn, mouse  choose a row
--   r          refresh        q                         quit
--   Delete     the tab's "d" action; other letters run the tab's actions
--
-- A tab is { title, load() -> rows | nil, err, describe(row) -> text, role?(row),
-- hints = { { key, label }... }, keys = { [char] = function(row, app) }, rowless? = {
-- [char] = true } }. An action runs with the selected row; actions listed in rowless
-- also run on an empty list (e.g. "add"). The list is loaded again after each action.
-- @module tab_app

local ui = import("ui")

local tab_app = {}

--- Run a tool until q.
-- @tparam table spec { title = string | function, right? = string | function,
--   tabs = { tab... }, message? = text shown at the start, message_role?,
--   on_start? = function(app) before the first draw (e.g. to keep the app for actions) }
-- @treturn table The app ({ set_message, refresh, selected, tab }) after it ended.
function tab_app.run(spec)
  local app = { tab = 1, rows = {}, list = ui.new_list(), message = spec.message,
    message_role = spec.message_role or "dim" }
  local tabs = spec.tabs

  function app.set_message(text, role)
    app.message, app.message_role = text, role or "dim"
  end

  function app.refresh()
    local rows, err = tabs[app.tab].load()
    app.rows = rows or {}
    if not rows then
      app.set_message(err, "error")
    end
  end

  function app.selected()
    return app.rows[app.list.selected]
  end

  local function value(field)
    if type(field) == "function" then
      return field()
    end
    return field
  end

  local function list_rows()
    local _, height = ui.size()
    return 3, height - 2
  end

  local function draw()
    local _, height = ui.size()
    ui.clear()
    ui.header(1, tostring(value(spec.title)), value(spec.right))
    local titles = {}
    for index, tab in ipairs(tabs) do
      titles[index] = tab.title
    end
    ui.tabs(2, titles, app.tab)
    local tab = tabs[app.tab]
    local lines, roles = {}, {}
    for index, row in ipairs(app.rows) do
      lines[index] = tab.describe(row)
      roles[index] = tab.role and tab.role(row) or nil
    end
    local top, bottom = list_rows()
    ui.draw_list(app.list, lines, top, bottom, roles)
    if app.message then
      ui.line(height - 1, app.message, app.message_role)
    end
    -- Quit first: hints that do not fit on a small screen are dropped from the end.
    local hints = { { "q", "Quit" } }
    for _, hint in ipairs(tab.hints or {}) do
      hints[#hints + 1] = hint
    end
    hints[#hints + 1] = { "r", "Refresh" }
    ui.footer(hints)
  end

  local function switch(index)
    if tabs[index] and index ~= app.tab then
      app.tab = index
      app.list = ui.new_list()
      app.set_message(nil)
      app.refresh()
    end
  end

  local function act(char)
    local tab = tabs[app.tab]
    local action = (tab.keys or {})[char]
    local row = app.selected()
    if action and (row or (tab.rowless or {})[char]) then
      action(row, app)
      app.refresh()
    end
  end

  if spec.on_start then
    spec.on_start(app)
  end
  app.refresh()
  local events = import("events")
  while true do
    draw()
    local event, a, _, c = events.pull()
    if event == "char" then
      local number = tonumber(a)
      if number then
        switch(number)
      elseif a == "q" then
        break
      elseif a == "r" then
        app.set_message(nil)
        app.refresh()
      else
        act(a)
      end
    elseif event == "key" then
      local top, bottom = list_rows()
      if a == keys.tab then
        switch(app.tab % #tabs + 1)
      elseif a == keys.delete then
        act("d")
      else
        ui.list_key(app.list, a, #app.rows, bottom - top + 1)
      end
    elseif event == "mouse_click" then
      local top, bottom = list_rows()
      local index = app.list.scroll + (c - top) + 1
      if c >= top and c <= bottom and app.rows[index] then
        app.list.selected = index
      end
    end
  end
  ui.clear()
  return app
end

return tab_app
