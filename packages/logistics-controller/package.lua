-- The version is set at build time: the release this package last changed in (tools/build.lua).
return {
  name = "logistics-controller",
  version = "0.0.0-dev",
  description = "The logistics controller: merges the nodes, routes requests, runs levels",
  depends = { logistics = ">=0.1.0-0" },
  optional = true,
}
