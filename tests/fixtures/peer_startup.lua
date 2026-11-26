-- Startup for the second emulated computer in tests/integration_spec.lua.
--
-- It plays two roles over a real modem:
--   * a BlockOS peer: hosts "peer-one" and announces itself every second
--   * a domain controller for domain "test" (admin / secret), plus an echo
--     service ("blockos.echo") used to check large messages
-- It shuts down after two minutes.

local LIFETIME_SECONDS = 120
local REPO = "/repo"

periphemu.create("top", "modem")
rednet.open("top")
rednet.host("blockos", "peer-one")
rednet.host("blockos.domain", "test")

-- Load BlockOS modules straight from the repository copy, like the test runner.
local loaded = {}
local function import(name)
  if loaded[name] ~= nil then
    return loaded[name]
  end
  for _, package_name in ipairs(fs.list(REPO .. "/packages")) do
    for _, kind in ipairs({ "kernel", "lib" }) do
      local dir = REPO .. "/packages/" .. package_name .. "/files/blockos/" .. kind
      local path = dir .. "/" .. name .. ".lua"
      if fs.exists(path) then
        local env = setmetatable({ import = import }, { __index = _G })
        loaded[name] = assert(loadfile(path, nil, env))()
        if name == "paths" then
          loaded[name].prefix = "/fixture"
        end
        return loaded[name]
      end
    end
  end
  error("module not found: " .. name)
end
_G.import = import

local rpc = import("rpc")
local dir = assert(import("directory").create("test", "admin", "secret"))
local storage = { save = function() return true end, has_room = function() return true end }
local domain_handlers = import("dc_handlers").new(dir, storage)

local function announce_loop()
  local announce = import("wire").event("announce",
    { hostname = "peer-one", kind = "computer", version = "test" })
  for _ = 1, LIFETIME_SECONDS do
    rednet.broadcast(announce, "blockos.announce")
    sleep(1)
  end
end

parallel.waitForAny(
  announce_loop,
  function() rpc.serve("blockos.domain", domain_handlers) end,
  function() rpc.serve("blockos.echo", { echo = function(_, args) return args end }) end
)
os.shutdown()
