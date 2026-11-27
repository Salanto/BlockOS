-- The version is set at build time: the release this package last changed in (tools/build.lua).
return {
  name = "logistics-protocol",
  version = "0.0.0-dev",
  kind = "protocol",
  description = "Logistics: the protocol, item and level logic, and the client library",
  depends = { net = ">=0.1.0-0" },
  optional = true,
  -- Managed mode (open to everyone until a domain admin runs `domain setup logistics-protocol`).
  -- Per-node roles (logistics-node-<node>) are added with `logistics node private`.
  roles = {
    { name = "logistics-admins", default = "installer",
      description = "May change levels, alarms, storage roles and nodes." },
    { name = "logistics-users", default = "everyone",
      description = "May look at storage and request items." },
  },
}
