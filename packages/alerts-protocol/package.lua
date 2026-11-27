-- The version is set at build time: the release this package last changed in (tools/build.lua).
return {
  name = "alerts-protocol",
  version = "0.0.0-dev",
  kind = "protocol",
  description = "Alerts: raise them from any program; the protocol and client library",
  depends = { net = ">=0.1.0-0" },
  optional = true,
  -- Managed mode (open to everyone until a domain admin runs `domain setup alerts`).
  -- Raising and reading alerts stay open to every computer: only channels are guarded.
  roles = {
    { name = "alerts-admins", default = "installer",
      description = "May add, change and test alert channels (Discord, mail, ...)." },
  },
}
