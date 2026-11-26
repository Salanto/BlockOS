--- Terminal UI helpers shared by every BlockOS screen.
--
-- Rules that keep basic and advanced devices behaving the same:
--
-- * Colours are only chosen through theme roles ("title", "error", ...), never
--   with term.setTextColour directly. Basic devices get a greyscale theme.
-- * Every screen works with the keyboard alone; mouse clicks are an extra.
-- * Layout always comes from term.getSize(); no fixed screen sizes.
-- @module ui

local device = import("device")

local ui = {}

local COLOUR_THEME = {
  bg = colours.black,
  text = colours.white,
  dim = colours.lightGrey,
  input = colours.white,
  title = colours.yellow,
  ok = colours.lime,
  warn = colours.orange,
  error = colours.red,
  bar = colours.blue,
  bar_text = colours.white,
  selected = colours.cyan,
  selected_text = colours.black,
}

-- Basic terminals display greyscale: only white, black, grey and light grey.
local GREYSCALE_THEME = {
  bg = colours.black,
  text = colours.white,
  dim = colours.lightGrey,
  input = colours.white,
  title = colours.white,
  ok = colours.white,
  warn = colours.white,
  error = colours.white,
  bar = colours.white,
  bar_text = colours.black,
  selected = colours.white,
  selected_text = colours.black,
}

--- @treturn table The theme for this device.
function ui.theme()
  if device.is_advanced() then
    return COLOUR_THEME
  end
  return GREYSCALE_THEME
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

--- Draw a full-width title bar with centred text.
-- @tparam number y Row.
-- @tparam string text
function ui.bar(y, text)
  local width = ui.size()
  text = ui.fit(text, width)
  ui.use("bar_text", "bar")
  term.setCursorPos(1, y)
  term.clearLine()
  term.setCursorPos(math.floor((width - #text) / 2) + 1, y)
  term.write(text)
  ui.reset()
end

--- Write one line of text at a position, clipped to the screen.
-- @tparam number y Row.
-- @param text
-- @tparam[opt="text"] string role
-- @tparam[opt=1] number x Column.
function ui.line(y, text, role, x)
  x = x or 1
  local width = ui.size()
  ui.use(role or "text")
  term.setCursorPos(x, y)
  term.write(ui.fit(text, width - x + 1))
  ui.reset()
end

--- print() in a colour role.
-- @param text
-- @tparam[opt="text"] string role
function ui.print(text, role)
  ui.use(role or "text")
  print(text)
  ui.reset()
end

--- Ask for a line of input.
--
-- Like read(), this raises "Terminated" on Ctrl+T; callers decide what that means.
-- @tparam string label Shown before the input.
-- @tparam[opt] table options { mask = "*", default = "text" }
-- @treturn string
function ui.prompt(label, options)
  options = options or {}
  ui.use("text")
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

local function draw_menu(menu, state)
  local width, height = ui.size()
  ui.clear()
  ui.bar(1, menu.title or "BlockOS")

  local y = 3
  if menu.text then
    local last_text_row = height - #menu.items - 2
    for _, line in ipairs(ui.wrap(menu.text, width)) do
      if y > last_text_row then
        break
      end
      ui.line(y, line)
      y = y + 1
    end
    y = y + 1
  end

  state.first_item_row = y
  for index, label in ipairs(menu.items) do
    if index == state.selected then
      ui.use("selected_text", "selected")
      term.setCursorPos(1, y)
      term.clearLine()
      term.write(ui.fit(" > " .. label, width))
      ui.reset()
    else
      ui.line(y, "   " .. label)
    end
    y = y + 1
  end

  local footer = "Up/Down, Enter"
  if state.seconds_left then
    local default_label = menu.items[menu.default or 1]
    footer = "Auto: " .. default_label .. " in " .. state.seconds_left .. "s"
  end
  ui.line(height, footer, "dim")
end

--- Show a keyboard-driven menu.
--
-- Ctrl+T is ignored, so a menu can never be used to escape to a shell.
-- @tparam table menu
--   title   (string) bar text
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

return ui
