-- The version is set at build time: the release this package last changed in (tools/build.lua).
return {
  name = "core",
  version = "0.0.0-dev",
  description = "BlockOS kernel, session, package manager and installers",
  depends = {},
  -- Only needed to build install media (the installers read them straight from
  -- the package), so they are not installed into /blockos.
  media_only = { "blockos/installer/", "blockos/loader.lua" },
}
