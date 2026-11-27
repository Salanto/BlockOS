-- The version is set at build time: the release this package last changed in (tools/build.lua).
return {
  name = "players-protocol",
  version = "0.0.0-dev",
  kind = "protocol",
  description = "Where players are: the protocol (player-locator answers it)",
  depends = { net = ">=0.1.0-0" },
  optional = true,
}
