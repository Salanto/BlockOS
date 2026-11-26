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

  -- Findable without a domain too: `pkg` looks the protocol up with rednet
  -- when nothing else is configured.
  if rednet.isOpen() and blockos.net and blockos.net.hostname() then
    pcall(rednet.host, "blockos.pkg", blockos.net.hostname())
  end

  -- Make this server findable as the domain's "pkg" service.
  local found, domain = pcall(import, "domain")
  if found and domain.is_joined() then
    local ok, err = domain.register_service("pkg", "blockos.pkg")
    if not ok then
      ctx.log.warn("could not register the pkg service record: %s", tostring(err))
    end
  end
  rpc.serve("blockos.pkg", repo.handlers())
end

return {
  name = "pkg-server",
  description = "Serves packages to other computers",
  after = { "net", "domain-client" },
  restart = "on-failure",
  run = run,
}
