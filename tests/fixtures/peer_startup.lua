-- Startup for the second emulated computer in tests/integration_spec.lua.
-- It plays a BlockOS peer: hosts "peer-one" and announces itself every second.
periphemu.create("top", "modem")
rednet.open("top")
rednet.host("blockos", "peer-one")

local announce = { v = 1, hostname = "peer-one", kind = "computer", version = "test" }
for _ = 1, 30 do
  rednet.broadcast(announce, "blockos.announce")
  sleep(1)
end
os.shutdown()
