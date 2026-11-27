--- Terminal UI helpers shared by every BlockOS screen and command.
--
-- Rules that keep basic and advanced devices behaving the same:
--
-- * Colours are only chosen through theme roles ("title", "error", ...), never
--   with term.setTextColour directly. Basic devices get a greyscale theme.
-- * Every screen works with the keyboard alone; mouse clicks are an extra.
-- * Layout always comes from term.getSize(); no fixed screen sizes.
-- * Only characters from CC's own font are used (see ui.GLYPHS).
-- @module ui

local device = import("device")

local ui = {}

--- Special characters of the CC font, by meaning.
ui.GLYPHS = {
  bullet = "\7",     -- a round dot
  pointer = "\16",   -- a right-pointing triangle
  up = "\24",
  down = "\25",
  dot = "\183",      -- a middle dot, for separators
  rule = "\140",     -- a horizontal line through the middle of the cell
}

local COLOUR_THEME = {
  bg = colours.black,
  text = colours.white,
  dim = colours.lightGrey,
  faint = colours.grey,
  input = colours.white,
  input_bg = colours.black,
  title = colours.yellow,
  ok = colours.lime,
  warn = colours.orange,
  error = colours.red,
  key = colours.yellow,
  bar = colours.blue,
  bar_text = colours.white,
  bar_dim = colours.lightBlue,
  panel = colours.grey,
  panel_text = colours.white,
  selected = colours.cyan,
  selected_text = colours.black,
  logo_top = colours.lime,
  logo_side = colours.brown,
}

-- Basic terminals display greyscale: only white, black, grey and light grey.
local GREYSCALE_THEME = {
  bg = colours.black,
  text = colours.white,
  dim = colours.lightGrey,
  faint = colours.grey,
  input = colours.white,
  input_bg = colours.black,
  title = colours.white,
  ok = colours.white,
  warn = colours.white,
  error = colours.white,
  key = colours.white,
  bar = colours.lightGrey,
  bar_text = colours.black,
  bar_dim = colours.grey,
  panel = colours.grey,
  panel_text = colours.white,
  selected = colours.white,
  selected_text = colours.black,
  logo_top = colours.white,
  logo_side = colours.lightGrey,
}

--- Set while drawing on another screen (e.g. a monitor) whose colour support
-- differs from the computer's own: true, false, or nil to follow the device.
ui.colour_override = nil

--- @treturn table The theme for this device (or for the screen being drawn on).
function ui.theme()
  local is_colour = ui.colour_override
  if is_colour == nil then
    is_colour = device.is_advanced()
  end
  if is_colour then
    return COLOUR_THEME
  end
  return GREYSCALE_THEME
end

--- Draw on another screen with its own colour support, then switch back.
-- @tparam table target A terminal object, e.g. a wrapped monitor.
-- @tparam function draw Called with no arguments while redirected.
function ui.draw_on(target, draw)
  local previous = term.redirect(target)
  ui.colour_override = target.isColour()
  local ok, err = pcall(draw)
  ui.colour_override = nil
  term.redirect(previous)
  if not ok then
    error(err, 0)
  end
end

--- Set the text (and optionally background) colour by role.
-- @tparam string text_role e.g. "error"
-- @tparam[opt="bg"] string background_role
function ui.use(text_role, background_role)
  local theme = ui.theme()
  term.setTextColour(theme[text_role] or theme.text)
  term.setBackgroundColour(theme[background_role or "bg"] or theme.bg)
end

--- Restore the default colours.
function ui.reset()
  ui.use("text", "bg")
end

--- Clear the screen and move the cursor to the top left.
function ui.clear()
  ui.reset()
  term.clear()
  term.setCursorPos(1, 1)
end

--- @treturn number width
-- @treturn number height
function ui.size()
  return term.getSize()
end

--- Cut text to a maximum width.
-- @param text
-- @tparam number width
-- @treturn string
function ui.fit(text, width)
  text = tostring(text)
  if width <= 0 then
    return ""
  end
  return text:sub(1, width)
end

--- Pad or cut text to exactly `width` characters.
-- @param text
-- @tparam number width
-- @treturn string
function ui.pad(text, width)
  text = ui.fit(text, width)
  return text .. string.rep(" ", width - #text)
end

--- Word-wrap text.
-- @tparam string text May contain newlines.
-- @tparam number width
-- @treturn {string...} Lines.
function ui.wrap(text, width)
  local lines = {}
  for paragraph in (tostring(text) .. "\n"):gmatch("(.-)\n") do
    local line = ""
    for word in paragraph:gmatch("%S+") do
      while #word > width do
        if line ~= "" then
          lines[#lines + 1] = line
          line = ""
        end
        lines[#lines + 1] = word:sub(1, width)
        word = word:sub(width + 1)
      end
      if line == "" then
        line = word
      elseif #line + 1 + #word <= width then
        line = line .. " " .. word
      else
        lines[#lines + 1] = line
        line = word
      end
    end
    lines[#lines + 1] = line
  end
  return lines
end

------------------------------------------------------------------------------
-- Drawing on full-screen screens
------------------------------------------------------------------------------

--- Fill a rectangle with a background role.
-- @tparam number x
-- @tparam number y
-- @tparam number width
-- @tparam number height
-- @tparam string role
function ui.fill(x, y, width, height, role)
  ui.use("text", role)
  local blank = string.rep(" ", width)
  for row = y, y + height - 1 do
    term.setCursorPos(x, row)
    term.write(blank)
  end
  ui.reset()
end

--- Write text at a position in a colour role, clipped to the screen.
-- @tparam number x
-- @tparam number y
-- @param text
-- @tparam[opt="text"] string role
-- @tparam[opt="bg"] string background_role
function ui.text_at(x, y, text, role, background_role)
  local width = ui.size()
  ui.use(role or "text", background_role)
  term.setCursorPos(x, y)
  term.write(ui.fit(text, width - x + 1))
  ui.reset()
end

--- Write text centred on a row.
-- @tparam number y
-- @param text
-- @tparam[opt="text"] string role
-- @tparam[opt="bg"] string background_role
function ui.center(y, text, role, background_role)
  local width = ui.size()
  text = ui.fit(text, width)
  ui.text_at(math.floor((width - #text) / 2) + 1, y, text, role, background_role)
end

--- Write one line of text, clipped to the screen.
-- @tparam number y Row.
-- @param text
-- @tparam[opt="text"] string role
-- @tparam[opt=1] number x Column.
function ui.line(y, text, role, x)
  ui.text_at(x or 1, y, text, role)
end

--- Full-width bar with a title on the left and optional text on the right.
-- @tparam number y Row.
-- @tparam string title
-- @tparam[opt] string right
function ui.header(y, title, right)
  local width = ui.size()
  ui.fill(1, y, width, 1, "bar")
  ui.text_at(2, y, title, "bar_text", "bar")
  if right then
    right = ui.fit(right, math.max(0, width - #title - 4))
    ui.text_at(width - #right, y, right, "bar_dim", "bar")
  end
end

--- Full-width bar with centred text (kept for simple screens).
-- @tparam number y Row.
-- @tparam string text
function ui.bar(y, text)
  local width = ui.size()
  ui.fill(1, y, width, 1, "bar")
  ui.center(y, text, "bar_text", "bar")
end

--- Key hints on the bottom row, e.g. { { "Enter", "Select" }, { "q", "Quit" } }.
-- Keys are highlighted; hints that do not fit are left out.
-- @tparam {table...} hints
-- @tparam[opt] string right Text for the right end (e.g. a countdown).
function ui.footer(hints, right)
  local width, height = ui.size()
  ui.fill(1, height, width, 1, "bg")
  local x = 1
  local limit = width - (right and #right + 1 or 0)
  for _, hint in ipairs(hints) do
    local key, label = hint[1], " " .. hint[2] .. "  "
    if x + #key + #label - 1 > limit then
      break
    end
    ui.text_at(x, height, key, "key")
    ui.text_at(x + #key, height, label, "dim")
    x = x + #key + #label
  end
  if right then
    ui.text_at(width - #right + 1, height, right, "dim")
  end
end

--- A small grass-block logo (6x3), drawn with background colours.
-- @tparam number x
-- @tparam number y
function ui.logo(x, y)
  ui.fill(x, y, 6, 1, "logo_top")
  ui.fill(x, y + 1, 6, 2, "logo_side")
  ui.fill(x + 1, y + 1, 1, 1, "logo_top")
  ui.fill(x + 4, y + 1, 1, 1, "logo_top")
end

local PANEL_MAX_WIDTH = 36

--- @treturn number The content width a panel will have on this screen.
function ui.panel_width()
  local screen_width = ui.size()
  return math.min(screen_width - 2, PANEL_MAX_WIDTH) - 2
end

--- A centred panel: a filled box with a title row. Small screens get the full width.
-- @tparam number height Rows including the title.
-- @tparam[opt] string title
-- @tparam[opt] number top Row of the panel (default: centred).
-- @treturn number x Left column of the panel content.
-- @treturn number y Row of the first content line.
-- @treturn number width Content width.
function ui.panel(height, title, top)
  local screen_width, screen_height = ui.size()
  local width = ui.panel_width() + 2
  local x = math.floor((screen_width - width) / 2) + 1
  local y = top or math.max(2, math.floor((screen_height - height) / 2) + 1)
  ui.fill(x, y, width, height, "panel")
  if title then
    ui.text_at(x + 1, y, title, "title", "panel")
  end
  return x + 1, y + (title and 2 or 1), width - 2
end

--- Ask for input in a field that stays inside its box.
--
-- Like read(), this raises "Terminated" on Ctrl+T; callers decide what that means.
-- @tparam number x
-- @tparam number y
-- @tparam number width Field width, including the label.
-- @tparam string label
-- @tparam[opt] table options { mask = "*", default = "text", background = role }
-- @treturn string
function ui.field_prompt(x, y, width, label, options)
  options = options or {}
  ui.text_at(x, y, label, "panel_text", options.background or "panel")
  local field_width = math.max(1, width - #label)
  local field = window.create(term.current(), x + #label, y, field_width, 1)
  local previous = term.redirect(field)
  ui.use("input", "input_bg")
  term.clear()
  term.setCursorPos(1, 1)
  local ok, result = pcall(read, options.mask, nil, nil, options.default)
  term.redirect(previous)
  ui.reset()
  if not ok then
    error(result, 0)
  end
  return result
end

------------------------------------------------------------------------------
-- Printing in commands
------------------------------------------------------------------------------

--- print() in a colour role.
-- @param text
-- @tparam[opt="text"] string role
function ui.print(text, role)
  ui.use(role or "text")
  print(text)
  ui.reset()
end

--- A section title followed by a thin line.
-- @tparam string text
function ui.title(text)
  local width = ui.size()
  ui.print(text, "title")
  ui.print(string.rep(ui.GLYPHS.rule, math.min(width, #text + 2)), "faint")
end

--- An aligned "label  value" line.
-- @tparam string label
-- @param value
-- @tparam[opt="text"] string role Colour of the value.
-- @tparam[opt=10] number label_width
function ui.field(label, value, role, label_width)
  ui.use("dim")
  write(ui.pad(label, label_width or 10))
  ui.print(tostring(value), role)
end

--- A coloured status dot followed by text, e.g. ui.status("running", "ok").
-- @tparam string text
-- @tparam string role
function ui.status(text, role)
  ui.use(role)
  write(ui.GLYPHS.bullet .. " ")
  ui.print(text, role)
end

--- Print rows as aligned columns that fit the screen.
--
-- The last column takes whatever width is left; others shrink when needed.
-- @tparam {table...} columns { { title = "HOST", key = "hostname" }, ... }; `key`
--   may also be a function(row) -> text.
-- @tparam {table...} rows
-- @tparam[opt] function row_role function(row) -> colour role for that row.
function ui.table(columns, rows, row_role)
  local width = ui.size()
  local function cell(column, row)
    local value = type(column.key) == "function" and column.key(row) or row[column.key]
    return tostring(value == nil and "" or value)
  end

  local widths, total = {}, 0
  for index, column in ipairs(columns) do
    local longest = #column.title
    for _, row in ipairs(rows) do
      longest = math.max(longest, #cell(column, row))
    end
    widths[index] = longest
    total = total + longest + 1
  end
  -- Shrink the widest columns until everything fits.
  while total - 1 > width do
    local widest = 1
    for index = 2, #widths do
      if widths[index] > widths[widest] then
        widest = index
      end
    end
    if widths[widest] <= 4 then
      break
    end
    widths[widest] = widths[widest] - 1
    total = total - 1
  end

  local function print_row(values, role)
    local parts = {}
    for index, value in ipairs(values) do
      parts[index] = ui.pad(value, widths[index])
    end
    ui.print(ui.fit(table.concat(parts, " "), width), role)
  end

  local titles = {}
  for index, column in ipairs(columns) do
    titles[index] = column.title
  end
  print_row(titles, "dim")
  for _, row in ipairs(rows) do
    local values = {}
    for index, column in ipairs(columns) do
      values[index] = cell(column, row)
    end
    print_row(values, row_role and row_role(row) or "text")
  end
  if #rows == 0 then
    ui.print("  (none)", "faint")
  end
end

------------------------------------------------------------------------------
-- Input
------------------------------------------------------------------------------

--- Ask for a line of input on the current line.
--
-- Like read(), this raises "Terminated" on Ctrl+T; callers decide what that means.
-- @tparam string label Shown before the input.
-- @tparam[opt] table options { mask = "*", default = "text" }
-- @treturn string
function ui.prompt(label, options)
  options = options or {}
  ui.use("dim")
  write(label)
  ui.use("input")
  local ok, result = pcall(read, options.mask, nil, nil, options.default)
  ui.reset()
  if not ok then
    error(result, 0)
  end
  return result
end

--- Wait for a key press or click. Ctrl+T is ignored.
function ui.wait_for_key()
  while true do
    local event = os.pullEventRaw()
    if event == "key" or event == "char" or event == "mouse_click" then
      return
    end
  end
end

local MENU_HINTS = {
  { ui.GLYPHS.up .. ui.GLYPHS.down, "Move" },
  { "Enter", "Select" },
}

local function draw_menu(menu, state)
  local width, height = ui.size()
  ui.clear()
  ui.header(1, menu.title or "BlockOS")

  local y = 3
  if menu.text then
    local last_text_row = height - #menu.items - 3
    for _, line in ipairs(ui.wrap(menu.text, width - 2)) do
      if y > last_text_row then
        break
      end
      ui.line(y, line, "dim", 2)
      y = y + 1
    end
    y = y + 1
  end

  state.first_item_row = y
  for index, label in ipairs(menu.items) do
    if index == state.selected then
      ui.fill(1, y, width, 1, "selected")
      ui.text_at(2, y, ui.GLYPHS.pointer .. " " .. label, "selected_text", "selected")
    else
      ui.text_at(4, y, label)
    end
    y = y + 1
  end

  local countdown = nil
  if state.seconds_left then
    countdown = "Auto: " .. menu.items[menu.default or 1] .. " in " .. state.seconds_left .. "s"
  end
  ui.footer(MENU_HINTS, countdown)
end

--- Show a keyboard-driven menu.
--
-- Ctrl+T is ignored, so a menu can never be used to escape to a shell.
-- @tparam table menu
--   title   (string) header text
--   text    (string, optional) wrapped intro text
--   items   ({string...}) option labels
--   default (number, optional) initially selected index, default 1
--   timeout (number, optional) seconds until `default` is chosen; any key stops it
-- @treturn number The chosen index.
function ui.menu(menu)
  local items = menu.items
  local state = { selected = menu.default or 1, seconds_left = menu.timeout }
  local timer = state.seconds_left and os.startTimer(1)

  draw_menu(menu, state)
  while true do
    local event, a, _, c = os.pullEventRaw()

    if event == "timer" and a == timer then
      state.seconds_left = state.seconds_left - 1
      if state.seconds_left <= 0 then
        ui.clear()
        return menu.default or 1
      end
      timer = os.startTimer(1)

    elseif event == "key" or event == "char" or event == "mouse_click" then
      state.seconds_left = nil
      timer = nil
      local choice = nil
      if event == "key" then
        if a == keys.up or a == keys.w then
          state.selected = (state.selected - 2) % #items + 1
        elseif a == keys.down or a == keys.s then
          state.selected = state.selected % #items + 1
        elseif a == keys.enter or a == keys.numPadEnter then
          choice = state.selected
        end
      elseif event == "char" then
        local number = tonumber(a)
        if number and items[number] then
          choice = number
        end
      else
        local index = c - state.first_item_row + 1
        if items[index] then
          choice = index
        end
      end
      if choice then
        ui.clear()
        return choice
      end
    end

    draw_menu(menu, state)
  end
end

------------------------------------------------------------------------------
-- Widgets for full-screen tools (e.g. dsa). Each draws into rows it is given
-- and keeps its state in a plain table, so callers own the event loop.
------------------------------------------------------------------------------

--- Draw a row of tabs. Tabs are numbered so they can be picked with number keys.
-- @tparam number y Row.
-- @tparam {string...} labels
-- @tparam number selected Index of the active tab.
function ui.tabs(y, labels, selected)
  local width = ui.size()
  ui.fill(1, y, width, 1, "panel")
  local full_width = 0
  for index, label in ipairs(labels) do
    full_width = full_width + #(" " .. index .. " " .. label .. " ")
  end
  -- Too many tabs for the screen: the others shrink to their number.
  local is_compact = full_width > width
  local x = 1
  for index, label in ipairs(labels) do
    local text = " " .. index .. " " .. label .. " "
    if is_compact and index ~= selected then
      text = " " .. index .. " "
    end
    if x + #text - 1 > width then
      break
    end
    if index == selected then
      ui.text_at(x, y, text, "selected_text", "selected")
    else
      ui.text_at(x, y, text, "panel_text", "panel")
    end
    x = x + #text
  end
end

--- Create the state of a scrolling list.
-- @treturn table { selected = 1, scroll = 0 }
function ui.new_list()
  return { selected = 1, scroll = 0 }
end

--- Draw a scrolling list of lines between two rows, with a scroll marker.
-- @tparam table list State from ui.new_list.
-- @tparam {string...} lines
-- @tparam number top First row.
-- @tparam number bottom Last row.
function ui.draw_list(list, lines, top, bottom)
  local width = ui.size()
  local rows = bottom - top + 1
  list.selected = math.max(1, math.min(list.selected, #lines))
  if list.selected <= list.scroll then
    list.scroll = list.selected - 1
  elseif list.selected > list.scroll + rows then
    list.scroll = list.selected - rows
  end

  for row = 0, rows - 1 do
    local index = list.scroll + row + 1
    local y = top + row
    local line = lines[index]
    ui.fill(1, y, width, 1, "bg")
    if line and index == list.selected then
      ui.fill(1, y, width, 1, "selected")
      ui.text_at(1, y, ui.GLYPHS.pointer .. " " .. line, "selected_text", "selected")
    elseif line then
      ui.text_at(3, y, line)
    end
  end
  if #lines == 0 then
    ui.line(top, "  (empty)", "faint")
  end
  if list.scroll > 0 then
    ui.text_at(width, top, ui.GLYPHS.up, "dim")
  end
  if list.scroll + rows < #lines then
    ui.text_at(width, bottom, ui.GLYPHS.down, "dim")
  end
end

--- Move a list's selection for a key press.
-- @tparam table list
-- @tparam number key A keys.* code.
-- @tparam number count Number of lines.
-- @tparam number page_size Rows visible.
-- @treturn boolean True if the key was handled.
function ui.list_key(list, key, count, page_size)
  if key == keys.up then
    list.selected = math.max(1, list.selected - 1)
  elseif key == keys.down then
    list.selected = math.min(math.max(count, 1), list.selected + 1)
  elseif key == keys.pageUp then
    list.selected = math.max(1, list.selected - page_size)
  elseif key == keys.pageDown then
    list.selected = math.min(math.max(count, 1), list.selected + page_size)
  elseif key == keys.home then
    list.selected = 1
  elseif key == keys["end"] then
    list.selected = math.max(count, 1)
  else
    return false
  end
  return true
end

--- Ask a yes/no question on the bottom row.
-- @tparam string question
-- @treturn boolean
function ui.confirm(question)
  local width, height = ui.size()
  ui.fill(1, height, width, 1, "bg")
  ui.text_at(1, height, question .. " ", "warn")
  ui.text_at(math.min(width - 4, #question + 2), height, "[y/N]", "key")
  while true do
    local event, value = os.pullEventRaw()
    if event == "char" then
      return value:lower() == "y"
    elseif event == "key" and (value == keys.enter or value == keys.backspace) then
      return false
    end
  end
end

--- Ask for one or more values in a centred panel. An empty first answer cancels.
-- @tparam string title
-- @tparam {table...} fields { label = "Name: ", mask = "*"?, default = "text"? }
-- @treturn {string...}|nil The answers, or nil when cancelled.
function ui.form(title, fields)
  ui.clear()
  local x, y, width = ui.panel(#fields + 4, title)
  ui.text_at(x, y + #fields + 1, "Empty first field cancels", "dim", "panel")
  local answers = {}
  for index, field in ipairs(fields) do
    local ok, answer = pcall(ui.field_prompt, x, y + index - 1, width, field.label,
      { mask = field.mask, default = field.default })
    if not ok or (index == 1 and answer == "") then
      ui.clear()
      return nil
    end
    answers[index] = answer
  end
  ui.clear()
  return answers
end

return ui
