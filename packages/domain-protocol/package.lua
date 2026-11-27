-- The version is set at build time: the release this package last changed in (tools/build.lua).
return {
  name = "domain-protocol",
  version = "0.0.0-dev",
  kind = "protocol",
  description = "The directory protocol: logins, records, roles (the domain client library)",
  depends = { net = ">=0.1.0-0" },
  optional = true,
}
