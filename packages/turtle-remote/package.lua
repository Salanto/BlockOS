-- The version is set at build time: the release this package last changed in (tools/build.lua).
return {
  name = "turtle-remote",
  version = "0.0.0-dev",
  kind = "application",
  description = "Lets this turtle be driven remotely (install turtle-tools on the PC)",
  -- Open without a domain; in a domain requests need a domain login.
  depends = { net = ">=0.1.0-0", ["turtle-protocol"] = ">=0.1.0-0" },
  optional = true,
}
