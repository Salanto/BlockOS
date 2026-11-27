-- The version is set at build time: the release this package last changed in (tools/build.lua).
return {
  name = "logistics-hub",
  version = "0.0.0-dev",
  kind = "library",
  description = "Logistics library: the merged view and levels (used by node and controller)",
  depends = { ["logistics-protocol"] = ">=0.1.0-0" },
  optional = true,
}
