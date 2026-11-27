-- The version is set at build time: the release this package last changed in (tools/build.lua).
return {
  name = "turtle-driver",
  version = "0.0.0-dev",
  description = "The remote command: drive turtles that run turtle-remote",
  depends = { net = ">=0.1.0-0", ["turtle-wire"] = ">=0.1.0-0" },
  optional = true,
}
