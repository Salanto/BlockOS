-- The version is set at build time: the release this package last changed in (tools/build.lua).
return {
  name = "logistics",
  version = "0.0.0-dev",
  kind = "bundle",
  description = "Logistics for a player's computer: the tools and boards",
  depends = { ["logistics-tools"] = ">=0.1.0-0", ["logistics-display"] = ">=0.1.0-0" },
  optional = true,
}
