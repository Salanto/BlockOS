#!/usr/bin/env bash
# Run the test suite in CraftOS-PC: tools/test.sh [advanced|basic|both] (default both).
set -euo pipefail
cd "$(dirname "$0")"

types=${1:-both}
if [ "$types" = "both" ]; then
  types="advanced basic"
fi

for computer_type in $types; do
  ./craftos-run.sh "$computer_type" "" /repo/tests/run.lua "$computer_type"
done
