-- The version is set at build time: the release this package last changed in (tools/build.lua).
return {
  name = "domain-controller",
  version = "0.0.0-dev",
  kind = "application",
  description = "Domain controller: users, groups, computers, names and services",
  depends = { ["domain-protocol"] = ">=0.1.0-0", ["alerts-protocol"] = ">=0.1.0-0" },
  optional = true,
  -- Every login and name lookup goes through the controller, so it runs alone.
  exclusive = true,
  -- ...except for packages that belong next to it (and what they need). Controllers
  -- from 0.4 and older have `domain` (a dependency back then; its services idle on the
  -- controller), and `domain-tools` brings dsa, which 0.4 had in `domain`.
  companions = { "mail-server", "alerts-hub", "domain", "domain-tools" },
}
