-- The version is set at build time: the release this package last changed in (tools/build.lua).
return {
  name = "domain",
  version = "0.0.0-dev",
  description = "Join a domain: domain logins, name lookups, dsa admin tool",
  depends = { core = ">=0.1.0-0", net = ">=0.1.0-0" },
  optional = true,
}
