-- The version is set at build time: the release this package last changed in (tools/build.lua).
return {
  name = "domain",
  version = "0.0.0-dev",
  kind = "application",
  description = "Join a domain: logins, name lookups, computer roles, remote admin",
  depends = { ["domain-protocol"] = ">=0.1.0-0" },
  optional = true,
}
