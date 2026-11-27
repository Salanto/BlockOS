-- The version is set at build time: the release this package last changed in (tools/build.lua).
return {
  name = "mail-tools",
  version = "0.0.0-dev",
  kind = "tools",
  description = "The mail app: read, write and answer mail",
  depends = { ["mail-protocol"] = ">=0.1.0-0" },
  optional = true,
}
