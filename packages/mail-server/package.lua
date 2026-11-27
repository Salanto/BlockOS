-- The version is set at build time: the release this package last changed in (tools/build.lua).
return {
  name = "mail-server",
  version = "0.0.0-dev",
  kind = "application",
  description = "Mail server: keeps the domain's mailboxes on disk drives",
  depends = { ["mail-protocol"] = ">=0.1.0-0", domain = ">=0.1.0-0" },
  optional = true,
}
