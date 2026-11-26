-- passwd [name]: change your password, or another user's (administrators only).
local args = { ... }
local ui = blockos.ui

local me = blockos.user
local target = args[1] or (me and me.name)

if not target then
  print("Usage: passwd [name]")
  return
end
local is_own_account = me ~= nil and target == me.name
if not is_own_account and not (me and me.is_admin) then
  ui.print("Only administrators can change other users' passwords.", "error")
  return
end

local password = ui.prompt("New password: ", { mask = "*" })
local repeated = ui.prompt("Repeat:       ", { mask = "*" })
if password ~= repeated then
  ui.print("Passwords do not match.", "error")
  return
end

local ok, err = blockos.auth.set_password(target, password)
if ok then
  ui.print("Password changed.", "ok")
else
  ui.print(err, "error")
end
