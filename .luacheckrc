-- luacheck configuration for BlockOS (CC:Tweaked Lua, roughly Lua 5.2).
std = "lua52"
max_line_length = 100
codes = true

-- `blockos` and `import` are the two globals the kernel defines on purpose.
globals = { "blockos", "import" }

-- CC:Tweaked APIs. `os` and `string` are listed with other_fields so CC's
-- additions (os.pullEvent, os.epoch, ...) are accepted.
read_globals = {
  os = { other_fields = true },
  "colours", "colors", "commands", "disk", "fs", "gps", "help", "http", "keys",
  "multishell", "paintutils", "parallel", "peripheral", "pocket", "printError",
  "read", "rednet", "settings", "shell", "sleep", "term", "textutils", "turtle",
  "vector", "window", "write",
  -- CraftOS-PC only (used by tests).
  "config", "periphemu",
}

exclude_files = { "dist/**" }
