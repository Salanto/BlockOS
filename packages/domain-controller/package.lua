-- The version is replaced by the release tag at build time (tools/build.lua).
return {
  name = "domain-controller",
  version = "0.0.0-dev",
  description = "Domain controller: users, groups, computers, names and services",
  depends = { domain = ">=0.1.0-0" },
  optional = true,
  -- Every login and name lookup goes through the controller, so it runs alone.
  exclusive = true,
}
