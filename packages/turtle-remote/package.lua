-- The version is set at build time: the release this package last changed in (tools/build.lua).
return {
  name = "turtle-remote",
  version = "0.0.0-dev",
  description = "Lets this turtle be driven remotely (install turtle-driver on the PC)",
  -- Open without a domain; in a domain requests need a domain login.
  depends = { net = ">=0.1.0-0", ["turtle-wire"] = ">=0.1.0-0" },
  optional = true,
  -- Managed mode: who may drive turtles (open to everyone until a domain admin sets it up).
  roles = {
    { name = "turtle-drivers", default = "everyone", description = "May drive turtles remotely." },
  },
}
