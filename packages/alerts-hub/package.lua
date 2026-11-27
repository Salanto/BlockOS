-- The version is set at build time: the release this package last changed in (tools/build.lua).
return {
  name = "alerts-hub",
  version = "0.0.0-dev",
  kind = "application",
  description = "Alert hub: sends alerts to Discord, webhooks, mail and other computers",
  depends = { ["alerts-protocol"] = ">=0.1.0-0" },
  optional = true,
}
