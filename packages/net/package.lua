-- The version is replaced by the release tag at build time (tools/build.lua).
return {
  name = "net",
  version = "0.0.0-dev",
  description = "Modems, hostname, peer discovery (built on rednet)",
  depends = { core = ">=0.1.0-0" },
}
