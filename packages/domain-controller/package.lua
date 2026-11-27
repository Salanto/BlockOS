-- The version is set at build time: the release this package last changed in (tools/build.lua).
return {
  name = "domain-controller",
  version = "0.0.0-dev",
  kind = "application",
  description = "Domain controller: users, groups, computers, names and services",
  depends = { ["domain-protocol"] = ">=0.1.0-0" },
  optional = true,
  -- Every login and name lookup goes through the controller, so it runs alone.
  exclusive = true,
}
