-- The version is set at build time: the release this package last changed in (tools/build.lua).
return {
  name = "msg-tools",
  version = "0.0.0-dev",
  kind = "tools",
  description = "The msg command: send and read instant messages",
  depends = { ["msg-protocol"] = ">=0.1.0-0" },
  optional = true,
}
