--- First-boot setup: create the administrator account.
--
-- Used by the session (when passwd is missing, empty or corrupt) and by both
-- installers.
-- @module setup

local auth = import("auth")
local device = import("device")
local ui = import("ui")

local setup = {}

-- Prompt again after Ctrl+T instead of aborting setup.
local function ask(label, options)
  while true do
    local ok, answer = pcall(ui.prompt, label, options)
    if ok then
      return answer
    end
    if answer ~= "Terminated" then
      error(answer, 0)
    end
    print()
  end
end

local function draw_intro()
  local width = ui.size()
  ui.clear()
  ui.bar(1, "BlockOS setup")
  term.setCursorPos(1, 3)
  local intro = "Create the administrator account for this " .. device.kind() .. "."
  for _, line in ipairs(ui.wrap(intro, width)) do
    ui.print(line)
  end
  print()
end

--- Interactively create the first administrator.
-- @treturn string The new user's name.
function setup.create_admin()
  while true do
    draw_intro()
    local name = ask("Username: ", { default = "admin" })
    local password = ask("Password: ", { mask = "*" })
    local repeated = ask("Repeat:   ", { mask = "*" })

    local ok, err
    if password ~= repeated then
      ok, err = nil, "passwords do not match"
    else
      ok, err = auth.add_user(name, password, true)
    end

    if ok then
      ui.print("Account '" .. name .. "' created.", "ok")
      return name
    end
    ui.print("Error: " .. err, "error")
    ui.print("Press any key to try again.", "dim")
    ui.wait_for_key()
  end
end

return setup
