-- The version is set at build time: the release this package last changed in (tools/build.lua).
return {
  name = "logistics-tools",
  version = "0.0.0-dev",
  kind = "tools",
  description = "The logistics command, full-screen tool and map",
  depends = { ["logistics-protocol"] = ">=0.1.0-0" },
  optional = true,
}
