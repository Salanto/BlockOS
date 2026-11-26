-- useradd <name> [--admin]: create a local account (administrators only).
local args = { ... }
local ui = blockos.ui

local name = args[1]
local make_admin = args[2] == "--admin"

if not name then
  print("Usage: useradd <name> [--admin]")
  return
end
if not (blockos.user and blockos.user.is_admin) then
  ui.print("Only administrators can add users.", "error")
  return
end

local password = ui.prompt("Password: ", { mask = "*" })
local repeated = ui.prompt("Repeat:   ", { mask = "*" })
if password ~= repeated then
  ui.print("Passwords do not match.", "error")
  return
end

local ok, err = blockos.auth.add_user(name, password, make_admin)
if ok then
  ui.print("User " .. name .. " created.", "ok")
else
  ui.print(err, "error")
end
