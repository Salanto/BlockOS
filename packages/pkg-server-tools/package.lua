-- The version is set at build time: the release this package last changed in (tools/build.lua).
return {
  name = "pkg-server-tools",
  version = "0.0.0-dev",
  kind = "tools",
  description = "The pkgserver command: manage a package server",
  depends = { ["pkg-server"] = ">=0.1.0-0" },
  optional = true,
}
