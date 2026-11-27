-- The version is set at build time: the release this package last changed in (tools/build.lua).
return {
  name = "turtle-protocol",
  version = "0.0.0-dev",
  kind = "protocol",
  description = "Turtle remote control: the protocol (turtle-remote and turtle-tools)",
  depends = { net = ">=0.1.0-0" },
  optional = true,
  -- Managed mode: who may drive turtles (open to everyone until a domain admin sets it up).
  roles = {
    { name = "turtle-drivers", default = "everyone", description = "May drive turtles remotely." },
  },
}
