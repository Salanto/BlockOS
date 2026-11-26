-- BlockOS loader. Installed as /startup.lua and never replaced by upgrades.
--
-- This file must stay small and self-contained: it is the only BlockOS code that
-- runs when /blockos is broken. It:
--
--  1. finishes or undoes an upgrade/rollback that was interrupted by a crash,
--  2. counts failed boots and rolls back (or gives up) when booting keeps failing,
--  3. runs the kernel and reboots if it ever stops, so a crash never drops the
--     user into an unauthenticated shell.
--
-- Test hooks: loader("--recover", prefix) and loader("--select-root", prefix)
-- run only steps 1 or 1-2 inside a sandbox directory.

local mode, prefix = ...
prefix = prefix or ""

local ROOT = prefix .. "/blockos"
local STAGING = prefix .. "/blockos.new"
local PREVIOUS = prefix .. "/blockos.old"
local STATE_FILE = prefix .. "/etc/blockos/upgrade.state"
local BOOTCOUNT_FILE = prefix .. "/etc/blockos/bootcount"
local LOG_FILE = prefix .. "/var/log/blockos.log"

local ROLLBACK_AT_FAILURE = 4
local GIVE_UP_AT_FAILURE = 7
local CRASH_REBOOT_SECONDS = 5

local function read_file(path)
  if not fs.exists(path) then
    path = path .. ".tmp"
  end
  if not fs.exists(path) then
    return nil
  end
  local handle = fs.open(path, "rb")
  local data = handle.readAll()
  handle.close()
  return data
end

local function write_file(path, data)
  local dir = fs.getDir(path)
  if not fs.exists(dir) then
    fs.makeDir(dir)
  end
  local handle = fs.open(path .. ".tmp", "wb")
  handle.write(data)
  handle.close()
  if fs.exists(path) then
    fs.delete(path)
  end
  fs.move(path .. ".tmp", path)
end

local function delete_if_exists(path)
  if fs.exists(path) then
    fs.delete(path)
  end
end

local function has_previous_version()
  return fs.exists(PREVIOUS .. "/boot.lua")
end

-- An upgrade writes "swap" only after the staged tree is complete and verified,
-- so it is always safe to roll forward.
local function finish_swap()
  if fs.exists(STAGING) then
    if fs.exists(ROOT) then
      delete_if_exists(PREVIOUS)
      fs.move(ROOT, PREVIOUS)
    end
    fs.move(STAGING, ROOT)
  elseif not fs.exists(ROOT) and fs.exists(PREVIOUS) then
    fs.move(PREVIOUS, ROOT)
  end
end

-- A rollback moves ROOT -> STAGING, PREVIOUS -> ROOT, STAGING -> PREVIOUS.
local function finish_rollback()
  if not fs.exists(ROOT) then
    if fs.exists(PREVIOUS) then
      fs.move(PREVIOUS, ROOT)
    elseif fs.exists(STAGING) then
      fs.move(STAGING, ROOT)
    end
  end
  if fs.exists(STAGING) then
    if fs.exists(PREVIOUS) then
      delete_if_exists(STAGING)
    else
      fs.move(STAGING, PREVIOUS)
    end
  end
end

local function recover_interrupted_swap()
  local state = read_file(STATE_FILE)
  if state == "swap" then
    finish_swap()
  elseif state == "rollback" then
    finish_rollback()
  elseif fs.exists(STAGING) and fs.exists(ROOT) then
    delete_if_exists(STAGING) -- abandoned before the swap started
  end
  delete_if_exists(STATE_FILE)
  delete_if_exists(STATE_FILE .. ".tmp")
end

local function roll_back()
  write_file(STATE_FILE, "rollback")
  delete_if_exists(STAGING)
  fs.move(ROOT, STAGING)
  fs.move(PREVIOUS, ROOT)
  fs.move(STAGING, PREVIOUS)
  delete_if_exists(STATE_FILE)
end

-- The kernel resets the counter once the login screen is up, so the count is the
-- number of boots in a row that never got that far.
local function select_root()
  local failures = (tonumber(read_file(BOOTCOUNT_FILE) or "0") or 0) + 1
  write_file(BOOTCOUNT_FILE, tostring(failures))

  local out_of_options = failures >= ROLLBACK_AT_FAILURE and not has_previous_version()
  if failures >= GIVE_UP_AT_FAILURE or out_of_options then
    return nil, "BlockOS failed to start repeatedly. Insert the BlockOS disk for recovery, "
      .. "or delete " .. BOOTCOUNT_FILE .. " and reboot to try again."
  end
  if failures == ROLLBACK_AT_FAILURE then
    roll_back()
    return ROOT, "BlockOS failed to start 3 times; rolled back to the previous version."
  end
  return ROOT
end

local function log_crash(message)
  pcall(function()
    local dir = fs.getDir(LOG_FILE)
    if not fs.exists(dir) then
      fs.makeDir(dir)
    end
    local time = os.date("!%Y-%m-%d %H:%M:%S", math.floor(os.epoch("utc") / 1000))
    local handle = fs.open(LOG_FILE, "ab")
    handle.write(time .. " [CRASH] loader: " .. tostring(message) .. "\n")
    handle.close()
  end)
end

local function run_kernel(root)
  local kernel, load_error = loadfile(root .. "/boot.lua", nil, _ENV)
  if not kernel then
    error(load_error, 0)
  end
  kernel(root, _ENV)
end

local function reset_terminal()
  term.redirect(term.native())
  term.setTextColour(colours.white)
  term.setBackgroundColour(colours.black)
  term.clear()
  term.setCursorPos(1, 1)
end

-- Ctrl+T must not interrupt the wait: that would drop to a shell.
local function wait_without_terminate(seconds)
  local timer = os.startTimer(seconds)
  while true do
    local event, id = os.pullEventRaw()
    if event == "timer" and id == timer then
      return
    end
  end
end

recover_interrupted_swap()
if mode == "--recover" then
  return
end

local root, note = select_root()
if mode == "--select-root" then
  return root, note
end

if not root then
  printError(note)
  return -- recovery: leave the user at a plain CraftOS shell
end
if not fs.exists(root .. "/boot.lua") then
  printError("BlockOS is not installed (" .. root .. "/boot.lua is missing).")
  printError("Use the BlockOS install disk.")
  return
end
if note then
  printError(note)
  log_crash(note)
end

-- The kernel never returns normally. Whatever happened, log it and reboot.
local ok, err = pcall(run_kernel, root)
local message = ok and "kernel exited unexpectedly" or tostring(err)
log_crash(message)
pcall(reset_terminal)
printError("BlockOS crashed: " .. message)
print("Rebooting in " .. CRASH_REBOOT_SECONDS .. " seconds...")
wait_without_terminate(CRASH_REBOOT_SECONDS)
os.reboot()
