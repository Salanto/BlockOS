-- The version is set at build time: the release this package last changed in (tools/build.lua).
return {
  name = "msg-protocol",
  version = "0.0.0-dev",
  kind = "protocol",
  description = "Instant messages between computers: the protocol",
  depends = { net = ">=0.1.0-0" },
  optional = true,
}
