#!/usr/bin/env bash
# Run a Lua program inside a fresh, headless CraftOS-PC computer.
#
#   tools/craftos-run.sh <advanced|basic> <copy-out dir or ""> <program> [args...]
#
# The repository is copied to /repo inside the computer. If a copy-out dir is
# given, the computer's /out directory is copied there afterwards.
# Exits non-zero if the program failed.
#
# Environment: CRAFTOS (default "craftos"), CRAFTOS_TIMEOUT (seconds, default 600).
set -euo pipefail

if [ "$#" -lt 3 ]; then
  echo "usage: $0 <advanced|basic> <copy-out dir or \"\"> <program> [args...]" >&2
  exit 2
fi

computer_type=$1
copy_out_dir=$2
shift 2

repo_dir=$(cd "$(dirname "$0")/.." && pwd)
craftos=${CRAFTOS:-craftos}
timeout_seconds=${CRAFTOS_TIMEOUT:-600}

data_dir=$(mktemp -d)
trap 'rm -rf "$data_dir"' EXIT
computer_dir="$data_dir/computer/0"
mkdir -p "$computer_dir/repo" "$data_dir/config"

cp -r "$repo_dir/packages" "$repo_dir/installer" "$repo_dir/tools" "$repo_dir/tests" \
  "$computer_dir/repo/"

is_color=true
if [ "$computer_type" = "basic" ]; then
  is_color=false
fi
printf '{ "isColor": %s }\n' "$is_color" > "$data_dir/config/0.json"

printf '%s\n' "$@" > "$computer_dir/harness-args"

# A second computer for multi-computer tests (started by tests via periphemu).
mkdir -p "$data_dir/computer/1"
cp "$repo_dir/tests/fixtures/peer_startup.lua" "$data_dir/computer/1/startup.lua"
printf 'shell.run("/repo/tools/harness.lua")\n' > "$computer_dir/startup.lua"

echo "Running $* on a $computer_type computer..."
timeout "$timeout_seconds" "$craftos" --headless --directory "$data_dir" --id 0 || true

if [ -n "$copy_out_dir" ] && [ -d "$computer_dir/out" ]; then
  mkdir -p "$copy_out_dir"
  cp -r "$computer_dir/out/." "$copy_out_dir/"
fi
if [ -f "$computer_dir/test-report.txt" ]; then
  cat "$computer_dir/test-report.txt"
fi

result=$(cat "$computer_dir/harness-result" 2>/dev/null || echo "no result")
if [ "$result" != "ok" ]; then
  echo "FAILED ($result)" >&2
  exit 1
fi
echo "OK"
