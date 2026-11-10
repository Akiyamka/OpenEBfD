#!/usr/bin/env bash
set -euo pipefail

project_dir="$(cd "$(dirname "$0")/.." && pwd)"
temp_dir="$(mktemp -d /tmp/openebfd-ap16-cost.XXXXXX)"
trap 'rm -rf "$temp_dir"' EXIT
cd "$project_dir"
git status --untracked-files=all

git show HEAD:scripts/combat/combat_target_acquisition.gd > "$temp_dir/head.gd"
expected="$(git rev-parse HEAD:scripts/combat/combat_target_acquisition.gd)"
actual="$(git hash-object "$temp_dir/head.gd")"
if [[ "$expected" != "$actual" ]]; then
  printf 'HEAD source hash mismatch\n' >&2
  exit 2
fi
printf 'HEAD blob %s SHA-256 %s\n' "$actual" "$(sha256sum "$temp_dir/head.gd" | cut -d' ' -f1)"
printf 'tree SHA-256 %s\n' "$(sha256sum scripts/combat/combat_target_acquisition.gd | cut -d' ' -f1)"
status=1
for attempt in 1 2; do
  printf 'AP16 cost attempt %d\n' "$attempt"
  git status --untracked-files=all > "$temp_dir/status-before-$attempt"
  if timeout 300 podman run --rm --userns=keep-id --security-opt label=disable \
    --volume "$project_dir:/workspace:ro" --volume "$temp_dir:/ap16head:ro" \
    --workdir /workspace openebfd-godot:4.7 godot --headless --path /workspace \
    --script res://tests/perf/target_acquisition_tie_cost_run.gd; then
    status=0
  fi
  git status --untracked-files=all > "$temp_dir/status-after-$attempt"
  diff -u "$temp_dir/status-before-$attempt" "$temp_dir/status-after-$attempt"
  if (( status == 0 )); then break; fi
done
git status --untracked-files=all
exit "$status"
