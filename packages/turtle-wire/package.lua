-- The version is set at build time: the release this package last changed in (tools/build.lua).
return {
  name = "turtle-wire",
  version = "0.0.0-dev",
  description = "The turtle remote protocol (used by turtle-remote and turtle-driver)",
  depends = { net = ">=0.1.0-0" },
  optional = true,
}
