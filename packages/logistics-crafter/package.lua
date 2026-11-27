-- The version is set at build time: the release this package last changed in (tools/build.lua).
return {
  name = "logistics-crafter",
  version = "0.0.0-dev",
  kind = "application",
  description = "Crafting on a logistics node: taught recipes, machines kept busy",
  depends = { ["logistics-node"] = ">=0.1.0-0" },
  optional = true,
  replaces = { "logistics-crafting" },
}
