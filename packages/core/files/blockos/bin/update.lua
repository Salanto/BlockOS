-- update: short alias for `pkg update` (same options), kept for habit's sake.
local args = { ... }

shell.run("pkg", "update", table.unpack(args))
