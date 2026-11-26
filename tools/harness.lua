-- Runs one program inside CraftOS-PC for tools/craftos-run.sh, records whether it
-- succeeded in /harness-result, then shuts the emulated computer down.
--
-- /harness-args holds the program and its arguments, one per line.

local RESULT_FILE = "/harness-result"

local function read_lines(path)
  local lines = {}
  local handle = fs.open(path, "r")
  if not handle then
    return lines
  end
  for line in handle.readAll():gmatch("[^\r\n]+") do
    lines[#lines + 1] = line
  end
  handle.close()
  return lines
end

local function write_result(text)
  local handle = fs.open(RESULT_FILE, "w")
  handle.write(text)
  handle.close()
end

local command = read_lines("/harness-args")
local program = table.remove(command, 1)

-- Programs report failure by raising an error (shell.run then returns false).
local ok, finished = pcall(shell.run, program, table.unpack(command))
if ok and finished then
  write_result("ok")
else
  write_result("failed")
end
os.shutdown()
