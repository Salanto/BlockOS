-- hostname [new name]: show or change this device's network name.
local args = { ... }
local ui = blockos.ui
local net = blockos.net

if not net then
  ui.print("The net service is not running.", "error")
  return
end

local new_name = args[1]
if not new_name then
  print(net.hostname() or "(none)")
  return
end
if not (blockos.user and blockos.user.is_admin) then
  ui.print("Only administrators can change the hostname.", "error")
  return
end

local clean, err = net.rename(new_name)
if not clean then
  ui.print(err, "error")
  return
end
ui.print("Hostname set to " .. clean .. ".", "ok")
