#!/usr/bin/env bash
set -euo pipefail
before="$(git status --porcelain --untracked-files=all)"
tmpdir="$(mktemp -d /tmp/ap9-head.XXXXXX)"
trap 'rm -rf "$tmpdir"' EXIT
for base in attack_arc_allocator orca_avoidance; do
  source="scripts/units/navigation/ground/${base}.gd"
  git show "HEAD:${source}" > "${tmpdir}/${base}_original.gd"
  test "$(git show "HEAD:${source}" | sha256sum | awk '{print $1}')" = \
    "$(sha256sum "${tmpdir}/${base}_original.gd" | awk '{print $1}')"
  git show "HEAD:${source}" | sed '/^class_name /d' > "${tmpdir}/${base}.gd"
  git show "HEAD:${source}" | sed '/^class_name /d' | sha256sum | awk '{print $1}' > "${tmpdir}/${base}.sha256"
  test "$(sha256sum "${tmpdir}/${base}.gd" | awk '{print $1}')" = "$(cat "${tmpdir}/${base}.sha256")"
done
set +e
if [[ "${1:-}" == "--oracle-head" ]]; then
  podman run --rm --userns=keep-id --security-opt label=disable --timeout 90 \
    --volume "$PWD:/workspace" --volume "${tmpdir}:/ap9_head:ro" \
    --volume "${tmpdir}/attack_arc_allocator_original.gd:/workspace/scripts/units/navigation/ground/attack_arc_allocator.gd:ro" \
    --volume "${tmpdir}/orca_avoidance_original.gd:/workspace/scripts/units/navigation/ground/orca_avoidance.gd:ro" \
    --workdir /workspace openebfd-godot:4.7 godot --headless --path /workspace \
    --script res://tests/navigation/portable_math_run.gd -- --oracle-only
else
  podman run --rm --userns=keep-id --security-opt label=disable --timeout 180 \
    --volume "$PWD:/workspace" --volume "${tmpdir}:/ap9_head:ro" --workdir /workspace \
    openebfd-godot:4.7 godot --headless --path /workspace \
    --script res://tests/perf/navigation_portable_math_cost_run.gd -- --warm-only
  warm_result=$?
  warm_after="$(git status --porcelain --untracked-files=all)"
  test "$before" = "$warm_after"
  if (( warm_result != 0 )); then
    exit "$warm_result"
  fi
  podman run --rm --userns=keep-id --security-opt label=disable --timeout 300 \
    --volume "$PWD:/workspace" --volume "${tmpdir}:/ap9_head:ro" --workdir /workspace \
    openebfd-godot:4.7 godot --headless --path /workspace \
    --script res://tests/perf/navigation_portable_math_cost_run.gd
fi
result=$?
set -e
after="$(git status --porcelain --untracked-files=all)"
test "$before" = "$after"
exit "$result"
