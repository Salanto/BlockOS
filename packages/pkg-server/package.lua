-- The version is set at build time: the release this package last changed in (tools/build.lua).
return {
  name = "pkg-server",
  version = "0.0.0-dev",
  kind = "application",
  description = "Package server: stores packages on this computer and disk drives, serves them",
  depends = { net = ">=0.1.0-0" },
  optional = true,
}
