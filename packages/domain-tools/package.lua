-- The version is set at build time: the release this package last changed in (tools/build.lua).
return {
  name = "domain-tools",
  version = "0.0.0-dev",
  kind = "tools",
  description = "Domain management: dsa, rsh, and the admin commands of domain",
  depends = { domain = ">=0.1.0-0" },
  optional = true,
}
