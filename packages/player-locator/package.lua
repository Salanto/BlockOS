-- The version is set at build time: the release this package last changed in (tools/build.lua).
return {
  name = "player-locator",
  version = "0.0.0-dev",
  kind = "application",
  description = "Says where players are, from an Advanced Peripherals Player Detector",
  depends = { ["players-protocol"] = ">=0.1.0-0" },
  optional = true,
}
