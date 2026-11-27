-- The version is set at build time: the release this package last changed in (tools/build.lua).
return {
  name = "msg",
  version = "0.0.0-dev",
  kind = "application",
  description = "Receives instant messages and shows them as notices",
  depends = { ["msg-protocol"] = ">=0.1.0-0" },
  optional = true,
}
