-- The version is set at build time: the release this package last changed in (tools/build.lua).
return {
  name = "mail-protocol",
  version = "0.0.0-dev",
  kind = "protocol",
  description = "Mail between players: the protocol and client library",
  depends = { net = ">=0.1.0-0" },
  optional = true,
}
