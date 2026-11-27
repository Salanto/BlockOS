-- The version is set at build time: the release this package last changed in (tools/build.lua).
return {
  name = "logistics-display",
  version = "0.0.0-dev",
  kind = "application",
  description = "Logistics boards (list and wall), redstone reactions and low-stock notices",
  depends = { ["logistics-protocol"] = ">=0.1.0-0" },
  optional = true,
}
