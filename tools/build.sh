#!/usr/bin/env bash
# Build release assets into dist/: tools/build.sh <version>
set -euo pipefail
cd "$(dirname "$0")/.."

version=${1:?usage: tools/build.sh <version>}
rm -rf dist

# Each package keeps the version of the release it last changed in: the build compares
# content checksums with the latest release's index (a missing index means "all changed").
previous=tools/previous-index.lua
repo=${GITHUB_REPOSITORY:-Salanto/BlockOS}
if ! curl -fsSL "https://github.com/$repo/releases/latest/download/index.lua" -o "$previous"; then
  echo "No previous release index found."
  rm -f "$previous"
fi
trap 'rm -f "$previous"' EXIT

tools/craftos-run.sh advanced dist /repo/tools/build.lua "$version" /out /repo
(cd dist/disk && zip -qr ../blockos-disk.zip .)
for addon in dist/addon-*/; do
  [ -d "$addon" ] || continue
  name=$(basename "$addon")
  (cd "$addon" && zip -qr "../blockos-$name.zip" .)
done
echo "Release assets:"
ls -l dist
