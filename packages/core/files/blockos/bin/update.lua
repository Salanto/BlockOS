-- update: short alias for `pkg update` (same options), kept for habit's sake.
-- `update --make-disk` still works and runs `pkg make-disk`.
local args = { ... }

local rest = {}
local is_make_disk = false
for _, value in ipairs(args) do
  if value == "--make-disk" then
    is_make_disk = true
  else
    rest[#rest + 1] = value
  end
end

shell.run("pkg", is_make_disk and "make-disk" or "update", table.unpack(rest))
