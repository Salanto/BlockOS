#!/usr/bin/env bash
# Build release assets into dist/: tools/build.sh <version>
set -euo pipefail
cd "$(dirname "$0")/.."

version=${1:?usage: tools/build.sh <version>}
rm -rf dist
tools/craftos-run.sh advanced dist /repo/tools/build.lua "$version" /out /repo
(cd dist/disk && zip -qr ../blockos-disk.zip .)
for addon in dist/addon-*/; do
  [ -d "$addon" ] || continue
  name=$(basename "$addon")
  (cd "$addon" && zip -qr "../blockos-$name.zip" .)
done
echo "Release assets:"
ls -l dist
