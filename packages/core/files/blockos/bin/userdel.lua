-- userdel <name>: remove a local account (administrators only).
local args = { ... }
local ui = blockos.ui

local name = args[1]
if not name then
  print("Usage: userdel <name>")
  return
end
if not (blockos.user and blockos.user.is_admin) then
  ui.print("Only administrators can remove users.", "error")
  return
end

local ok, err = blockos.auth.remove_user(name)
if ok then
  ui.print("User " .. name .. " removed.", "ok")
else
  ui.print(err, "error")
end
