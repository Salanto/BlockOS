-- BlockOS test runner. Runs inside CraftOS-PC (see tools/test.sh), so tests use
-- the real CC APIs instead of mocks.
--
--   run [advanced|basic] [repo dir]
--
-- Every tests/*_spec.lua file returns function(t) and registers tests with
-- t.it(name, fn). Results go to the terminal and to /test-report.txt; the run
-- fails (raises) if any test failed.

local args = { ... }
local expected_type = args[1]
local repo_dir = args[2] or "/repo"

local SANDBOX = "/sandbox"
local REPORT_FILE = "/test-report.txt"
-- Written line by line, so a run that hangs still shows where (tools/craftos-run.sh).
local PROGRESS_FILE = "/test-progress.txt"

-- Every package's kernel/ and lib/ directory, like /blockos/kernel and /blockos/lib
-- on an installed computer.
local function module_dirs()
  local dirs = {}
  for _, package_name in ipairs(fs.list(fs.combine(repo_dir, "packages"))) do
    for _, kind in ipairs({ "kernel", "lib" }) do
      dirs[#dirs + 1] = "packages/" .. package_name .. "/files/blockos/" .. kind
    end
  end
  return dirs
end

local MODULE_DIRS = module_dirs()

local results = { passed = 0, failed = 0, skipped = 0, lines = {} }

-- Headless CraftOS-PC always reports a colour terminal. BlockOS only tells basic
-- from advanced through term.isColour(), so a basic computer is simulated with a
-- terminal that reports no colour support. Windows created on top of it inherit that.
local function basic_terminal()
  local width, height = term.native().getSize()
  -- Invisible: a visible window redraws the whole native screen every time it scrolls,
  -- and headless CraftOS-PC turns each redraw into output, which made basic runs slow
  -- and erratic (minutes instead of seconds). The window still keeps its contents.
  local screen = window.create(term.native(), 1, 1, width, height, false)
  local function no_colour()
    return false
  end
  return setmetatable({ isColour = no_colour, isColor = no_colour }, { __index = screen })
end

local root_terminal = term.native()
if expected_type == "basic" then
  root_terminal = basic_terminal()
end
term.redirect(root_terminal)

local function progress(line)
  local handle = fs.open(PROGRESS_FILE, "a")
  handle.write(line .. "\n")
  handle.close()
end

local function report(line)
  print(line)
  results.lines[#results.lines + 1] = line
  progress(line)
end

------------------------------------------------------------------------------
-- The `t` helper passed to every spec
------------------------------------------------------------------------------

local t = {}

t.repo = repo_dir
t.sandbox = SANDBOX
t.computer_type = expected_type

--- Fail unless `value` is truthy.
function t.ok(value, message)
  if not value then
    error(message or "expected a true value", 2)
  end
end

--- Fail unless `actual == expected`.
function t.eq(actual, expected, message)
  if actual ~= expected then
    local text = string.format("expected %s, got %s", tostring(expected), tostring(actual))
    if message then
      text = message .. ": " .. text
    end
    error(text, 2)
  end
end

--- Skip the current test.
function t.skip(reason)
  error({ skip = reason }, 0)
end

--- A fresh copy of the BlockOS modules, with all paths inside the sandbox.
-- @treturn function import(name)
function t.fresh_import()
  local loaded = {}
  local function import(name)
    if loaded[name] ~= nil then
      return loaded[name]
    end
    for _, dir in ipairs(MODULE_DIRS) do
      local path = fs.combine(repo_dir, dir .. "/" .. name .. ".lua")
      if fs.exists(path) then
        local env = setmetatable({ import = import }, { __index = _G })
        loaded[name] = assert(loadfile(path, nil, env))()
        if name == "paths" then
          loaded[name].prefix = SANDBOX
        end
        return loaded[name]
      end
    end
    error("module not found: " .. name, 2)
  end
  _G.import = import
  return import
end

--- Empty the sandbox directory.
function t.reset_sandbox()
  if fs.exists(SANDBOX) then
    fs.delete(SANDBOX)
  end
  fs.makeDir(SANDBOX)
end

--- Write a file (creating directories).
function t.write(path, data)
  local handle = fs.open(path, "wb")
  if not handle then
    fs.makeDir(fs.getDir(path))
    handle = fs.open(path, "wb")
  end
  handle.write(data)
  handle.close()
end

--- Read a file, or nil.
function t.read(path)
  if not fs.exists(path) then
    return nil
  end
  local handle = fs.open(path, "rb")
  local data = handle.readAll()
  handle.close()
  return data
end

--- Run `fn` while feeding it events, as if the user typed them.
-- @tparam function fn
-- @tparam {table...} events e.g. { { "paste", "admin" }, { "key", keys.enter } };
--   { "wait", seconds } pauses the script.
-- @return Whatever fn returns.
function t.with_input(fn, events)
  -- Must ignore `terminate`: tests send it on purpose to check Ctrl+T handling.
  local function raw_sleep(seconds)
    local timer = os.startTimer(seconds)
    while true do
      local event, id = os.pullEventRaw()
      if event == "timer" and id == timer then
        return
      end
    end
  end

  local result = nil
  parallel.waitForAny(
    function() result = table.pack(fn()) end,
    function()
      for _, event in ipairs(events) do
        if event[1] == "wait" then
          raw_sleep(event[2]) -- let network calls finish before the next key
        else
          os.queueEvent(table.unpack(event))
          raw_sleep(0)
        end
      end
      raw_sleep(5) -- the code under test should have finished by now
      error("input script finished but the code under test is still waiting", 0)
    end
  )
  return table.unpack(result, 1, result.n)
end

--- A stand-in for the `peripheral` API over fake devices.
-- @tparam table devices [name] = { types = {...}, methods = {...} }
-- @treturn table With getNames, hasType, wrap, isPresent.
function t.fake_peripherals(devices)
  return {
    getNames = function()
      local names = {}
      for name in pairs(devices) do
        names[#names + 1] = name
      end
      table.sort(names)
      return names
    end,
    hasType = function(name, wanted)
      local device = devices[name]
      if not device then
        return nil
      end
      for _, kind in ipairs(device.types) do
        if kind == wanted then
          return true
        end
      end
      return false
    end,
    wrap = function(name)
      return devices[name] and devices[name].methods
    end,
    getType = function(name)
      local device = devices[name]
      if device then
        return table.unpack(device.types)
      end
      return nil
    end,
    isPresent = function(name)
      return devices[name] ~= nil
    end,
  }
end

--- A fake chest for t.fake_peripherals.
-- @tparam table slots [slot] = { name, count, label }
-- @treturn table
function t.fake_chest(slots)
  return {
    types = { "inventory" },
    methods = {
      list = function()
        local listed = {}
        for slot, stack in pairs(slots) do
          listed[slot] = { name = stack.name, count = stack.count }
        end
        return listed
      end,
      getItemDetail = function(slot)
        local stack = slots[slot]
        return stack and { name = stack.name, count = stack.count, displayName = stack.label }
      end,
    },
  }
end

--- Register a test.
-- Real time in seconds (os.clock is CPU time, which misses waiting).
local function now()
  return os.epoch("utc") / 1000
end

-- Tests slower than this show their time, so slow runs can be traced.
local SLOW_SECONDS = 1

local function timing(started)
  local seconds = now() - started
  return seconds >= SLOW_SECONDS and string.format(" (%.1fs)", seconds) or ""
end

function t.it(name, fn)
  t.reset_sandbox()
  _G.blockos = nil
  local started = now()
  progress("  ...   " .. name)
  local ok, err = pcall(fn)
  if ok then
    results.passed = results.passed + 1
    report("  ok    " .. name .. timing(started))
  elseif type(err) == "table" and err.skip then
    results.skipped = results.skipped + 1
    report("  skip  " .. name .. " (" .. tostring(err.skip) .. ")")
  else
    results.failed = results.failed + 1
    report("  FAIL  " .. name .. timing(started))
    report("        " .. tostring(err))
  end
  term.redirect(root_terminal)
  term.setTextColour(colours.white)
  term.setBackgroundColour(colours.black)
end

------------------------------------------------------------------------------
-- Run every spec
------------------------------------------------------------------------------

local function run_specs()
  local spec_dir = fs.combine(repo_dir, "tests")
  local spec_files = {}
  for _, file in ipairs(fs.list(spec_dir)) do
    if file:match("_spec%.lua$") then
      spec_files[#spec_files + 1] = file
    end
  end
  table.sort(spec_files)

  for _, file in ipairs(spec_files) do
    local started = now()
    report(file)
    local spec, load_error = loadfile(fs.combine(spec_dir, file), nil, _ENV)
    if not spec then
      results.failed = results.failed + 1
      report("  FAIL  could not load: " .. tostring(load_error))
    else
      local ok, err = pcall(spec(), t)
      if not ok then
        results.failed = results.failed + 1
        report("  FAIL  spec crashed: " .. tostring(err))
      end
    end
    report("  -- " .. file .. timing(started))
  end
end

local actual_type = term.isColour() and "advanced" or "basic"
report("BlockOS tests on a " .. actual_type .. " computer")

run_specs()

report(string.format("%d passed, %d failed, %d skipped",
  results.passed, results.failed, results.skipped))

local handle = fs.open(REPORT_FILE, "w")
handle.write(table.concat(results.lines, "\n") .. "\n")
handle.close()

if fs.exists(SANDBOX) then
  fs.delete(SANDBOX)
end
if results.failed > 0 then
  error("tests failed", 0)
end
