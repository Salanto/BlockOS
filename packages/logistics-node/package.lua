-- The version is set at build time: the release this package last changed in (tools/build.lua).
return {
  name = "logistics-node",
  version = "0.0.0-dev",
  description = "A logistics node: reads and sorts one storage network",
  depends = { logistics = ">=0.1.0-0" },
  optional = true,
  -- Takes over the old storage-monitor package (its config is migrated on first start).
  replaces = { "storage-monitor" },
}
