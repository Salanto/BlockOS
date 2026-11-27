-- pkg-server service: serves the packages stored on this computer's drives
-- (protocol "blockos.pkg"). It registers itself as the domain's "pkg" service
-- record at start, so other computers find it.

local function run(ctx)
  local repo = import("repo")
  local rpc = import("rpc")
  local count = 0
  for _ in pairs(repo.scan()) do
    count = count + 1
  end
  ctx.log.info("serving %d packages from %d drives", count, #repo.roots())

  -- Findable as the domain's "pkg" record, and by rednet name without a domain
  -- (several package servers may run: each hosts its own hostname).
  local pkg_remote = import("pkg_remote")
  local hostname = blockos.net and blockos.net.hostname() or ("#" .. os.getComputerID())
  local ok, err = import("discovery").advertise(pkg_remote.SERVICE_TYPE, pkg_remote.PROTOCOL,
    hostname)
  if not ok then
    ctx.log.warn("could not register the pkg service record: %s", tostring(err))
  end
  rpc.serve(pkg_remote.PROTOCOL, repo.handlers())
end

return {
  name = "pkg-server",
  description = "Serves packages to other computers",
  after = { "net", "domain-client" },
  restart = "on-failure",
  run = run,
}
