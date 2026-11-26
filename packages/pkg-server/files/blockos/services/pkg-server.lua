-- pkg-server service: serves the packages stored on this computer's drives
-- (protocol "blockos.pkg"). Register it in the domain once with
-- `domain dns add pkg <this hostname>` so other computers find it.

local function run(ctx)
  local repo = import("repo")
  local rpc = import("rpc")
  local count = 0
  for _ in pairs(repo.scan()) do
    count = count + 1
  end
  ctx.log.info("serving %d packages from %d drives", count, #repo.roots())
  rpc.serve("blockos.pkg", repo.handlers())
end

return {
  name = "pkg-server",
  description = "Serves packages to other computers",
  after = { "net", "domain-client" },
  restart = "on-failure",
  run = run,
}
