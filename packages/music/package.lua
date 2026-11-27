-- The version is set at build time: the release this package last changed in (tools/build.lua).
return {
  name = "music",
  version = "0.0.0-dev",
  kind = "tools",
  description = "Music player: plays .dfpwm files or links on attached speakers",
  depends = { core = ">=0.1.0-0" },
  optional = true,
}
