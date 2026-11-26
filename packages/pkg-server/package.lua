-- The version is replaced by the release tag at build time (tools/build.lua).
return {
  name = "pkg-server",
  version = "0.0.0-dev",
  description = "Package server: stores packages on disk drives and serves them",
  depends = { domain = ">=0.1.0-0" },
  optional = true,
}
