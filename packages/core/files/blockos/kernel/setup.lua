--- First-boot setup: create the administrator account.
--
-- Used by the session (when passwd is missing, empty or corrupt) and by both
-- installers.
-- @module setup

local auth = import("auth")
local device = import("device")
local ui = import("ui")

local setup = {}

local FIELD_COUNT = 3

-- Prompt again after Ctrl+T instead of aborting setup.
local function ask(x, y, width, label, options)
  while true do
    local ok, answer = pcall(ui.field_prompt, x, y, width, label, options)
    if ok then
      return answer
    end
    if answer ~= "Terminated" then
      error(answer, 0)
    end
  end
end

-- Draws the setup panel; returns where the fields go.
local function draw(message)
  ui.clear()
  ui.header(1, "BlockOS setup")
  local intro = "Create the administrator account for this " .. device.kind() .. "."
  local intro_lines = ui.wrap(intro, ui.panel_width())
  local x, y, width = ui.panel(#intro_lines + FIELD_COUNT + 5, "New administrator")
  for index, line in ipairs(intro_lines) do
    ui.text_at(x, y + index - 1, line, "dim", "panel")
  end
  local fields_y = y + #intro_lines + 1
  if message then
    ui.text_at(x, fields_y + FIELD_COUNT + 1, ui.fit(message, width), "error", "panel")
  end
  ui.footer({ { "Enter", "Next" } })
  return x, fields_y, width
end

--- Interactively create the first administrator.
-- @treturn string The new user's name.
function setup.create_admin()
  local message = nil
  while true do
    local x, y, width = draw(message)
    local name = ask(x, y, width, "Username ", { default = "admin" })
    local password = ask(x, y + 1, width, "Password ", { mask = "*" })
    local repeated = ask(x, y + 2, width, "Repeat   ", { mask = "*" })

    local ok, err
    if password ~= repeated then
      ok, err = nil, "Passwords do not match."
    else
      ok, err = auth.add_user(name, password, true)
    end
    if ok then
      ui.clear()
      return name
    end
    message = err
  end
end

return setup
