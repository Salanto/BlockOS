-- dcpromo: turn this computer into the domain controller of a new domain.
-- (Named after the Active Directory tool, for fun.)
local ui = blockos.ui

local DIRECTORY_FILE = "etc/blockos/directory"

if not (blockos.user and blockos.user.is_admin) then
  ui.print("Only administrators can create a domain.", "error")
  return
end
if not blockos.net then
  ui.print("The net service is not running.", "error")
  return
end

local paths = import("paths")
local fsx = import("fsx")
local directory = import("directory")
local domain = import("domain")

local directory_path = paths.top(DIRECTORY_FILE)
if fs.exists(directory_path) then
  ui.print("This computer is already a domain controller.", "warn")
  return
end
if domain.is_joined() then
  ui.print("This computer is a member of " .. domain.name() .. ". Leave it first.", "error")
  return
end

ui.print("Create a new domain", "title")
print("This computer becomes its domain controller. Keep it dedicated:")
print("other services should run on other computers.")
print()

local domain_name = ui.prompt("Domain name (e.g. home): ")
local admin_name = ui.prompt("First domain admin: ", { default = "admin" })
local password = ui.prompt("Password: ", { mask = "*" })
if ui.prompt("Repeat:   ", { mask = "*" }) ~= password then
  ui.print("Passwords do not match.", "error")
  return
end

local dir, err = directory.create(domain_name, admin_name, password)
if not dir then
  ui.print(err, "error")
  return
end

-- The controller is also a member of its own domain.
local computer_token = dir:join(blockos.net.hostname(), os.getComputerID())
fsx.write_table(directory_path, dir.data)
domain.set_membership({
  name = domain_name,
  controller_id = os.getComputerID(),
  computer_token = computer_token,
})

ui.print("Domain " .. domain_name .. " created. Rebooting to start the controller...", "ok")
sleep(2)
os.reboot()
