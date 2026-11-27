-- The version is set at build time: the release this package last changed in (tools/build.lua).
return {
  name = "logistics",
  version = "0.0.0-dev",
  description = "Item logistics: catalog, requests, levels and alarms (the tools)",
  -- Works on its own; in a domain it also uses logins, roles and service records.
  depends = { net = ">=0.1.0-0" },
  optional = true,
  -- Managed mode (open to everyone until a domain admin runs `domain setup logistics`).
  -- Per-node roles (logistics-node-<node>) are added with `logistics node private`.
  roles = {
    { name = "logistics-admins", default = "installer",
      description = "May change levels, alarms, storage roles and nodes." },
    { name = "logistics-users", default = "everyone",
      description = "May look at storage and request items." },
  },
}
