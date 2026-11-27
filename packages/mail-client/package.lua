-- The version is set at build time: the release this package last changed in (tools/build.lua).
return {
  name = "mail-client",
  version = "0.0.0-dev",
  kind = "application",
  description = "New-mail notices, sound and the blockos_mail event",
  depends = { ["mail-protocol"] = ">=0.1.0-0", domain = ">=0.1.0-0" },
  optional = true,
}
