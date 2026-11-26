-- Runs one program inside CraftOS-PC for tools/craftos-run.sh, records whether it
-- succeeded in /harness-result, then shuts the emulated computer down.
--
-- /harness-args holds the program and its arguments, one per line.
-- /harness-computer-type holds "advanced" or "basic".

local RESULT_FILE = "/harness-result"
local SWITCH_MARKER = "/harness-switched"

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

local function write_file(path, text)
  local handle = fs.open(path, "w")
  handle.write(text)
  handle.close()
end

local function finish(result)
  write_file(RESULT_FILE, result)
  os.shutdown()
end

-- CraftOS-PC may ignore a hand-written per-computer config file, so switch the
-- computer type through its config API and reboot into the right type.
local wanted_type = read_lines("/harness-computer-type")[1] or "advanced"
local is_advanced = term.isColour()
if (wanted_type == "advanced") ~= is_advanced then
  if fs.exists(SWITCH_MARKER) or not config then
    print("Could not switch the computer to " .. wanted_type)
    finish("wrong computer type")
    return
  end
  write_file(SWITCH_MARKER, wanted_type)
  config.set("isColor", wanted_type == "advanced")
  os.reboot()
  return
end

local command = read_lines("/harness-args")
local program = table.remove(command, 1)

-- Programs report failure by raising an error (shell.run then returns false).
local ok, finished = pcall(shell.run, program, table.unpack(command))
if ok and finished then
  finish("ok")
else
  finish("failed")
end
