-- The version is set at build time: the release this package last changed in (tools/build.lua).
return {
  name = "net",
  version = "0.0.0-dev",
  kind = "base",
  description = "Modems, hostname, peer discovery (built on rednet)",
  depends = { core = ">=0.1.0-0" },
}
