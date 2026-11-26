-- The version is replaced by the release tag at build time (tools/build.lua).
return {
  name = "turtle-remote",
  version = "0.0.0-dev",
  description = "Drive turtles remotely over rednet (domain logins)",
  -- Every request is checked with the domain controller, so it needs a domain.
  depends = { net = ">=0.1.0-0", domain = ">=0.1.0-0" },
  optional = true,
}
