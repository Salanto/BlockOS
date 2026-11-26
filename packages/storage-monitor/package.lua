-- The version is replaced by the release tag at build time (tools/build.lua).
return {
  name = "storage-monitor",
  version = "0.0.0-dev",
  description = "Watches stock in chests and raises alarms when items run low",
  depends = { domain = ">=0.1.0-0" },
  optional = true,
}
