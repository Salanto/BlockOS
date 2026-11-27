-- The version is set at build time: the release this package last changed in (tools/build.lua).
return {
  name = "turtle-tools",
  version = "0.0.0-dev",
  kind = "tools",
  description = "The remote command: drive turtles that run turtle-remote",
  depends = { net = ">=0.1.0-0", ["turtle-protocol"] = ">=0.1.0-0" },
  optional = true,
  replaces = { "turtle-driver" },
}
