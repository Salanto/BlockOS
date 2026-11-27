-- The version is set at build time: the release this package last changed in (tools/build.lua).
return {
  name = "alerts-tools",
  version = "0.0.0-dev",
  kind = "tools",
  description = "The alerts command: channels, active alerts, and watching alerts arrive",
  depends = { ["alerts-protocol"] = ">=0.1.0-0" },
  optional = true,
}
