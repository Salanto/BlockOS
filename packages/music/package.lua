-- The version is replaced by the release tag at build time (tools/build.lua).
return {
  name = "music",
  version = "0.0.0-dev",
  description = "Music player: plays .dfpwm files or links on attached speakers",
  depends = { core = ">=0.1.0-0" },
  optional = true,
}
