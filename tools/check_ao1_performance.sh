#!/usr/bin/env bash
# AO1's baseline deliberately overlays every runtime diff, not a hand-curated
# subset: a missing overlay would compare a mixed tree to HEAD.
set -euo pipefail
ao1_head_dir="$(mktemp -d /tmp/ao1-head.XXXXXX)"
trap 'rm -rf "$ao1_head_dir"' EXIT
mapfile -t ao1_runtime_files < <(git diff --diff-filter=M --name-only HEAD -- scripts/)
((${#ao1_runtime_files[@]})) || { echo 'AO1: no changed runtime files' >&2; exit 2; }
ao1_head_mounts=()
for ao1_path in "${ao1_runtime_files[@]}"; do
  mkdir -p "$ao1_head_dir/$(dirname "$ao1_path")"
  git show "HEAD:$ao1_path" > "$ao1_head_dir/$ao1_path"
  ao1_head_mounts+=(--volume "$ao1_head_dir/$ao1_path:/workspace/$ao1_path:ro")
done
for ao1_pair in 1 2 3; do
  timeout --foreground 360 podman run --rm --userns=keep-id --security-opt label=disable --timeout 300 \
    --volume "$PWD:/workspace:ro" "${ao1_head_mounts[@]}" --workdir /workspace openebfd-godot:4.7 \
    godot --headless --path /workspace --script res://tests/perf/headless_match_perf_run.gd -- \
    --ticks=3000 --warmup-ticks=200 --label="HEAD-$ao1_pair"
  timeout --foreground 360 podman run --rm --userns=keep-id --security-opt label=disable --timeout 300 \
    --volume "$PWD:/workspace:ro" --workdir /workspace openebfd-godot:4.7 \
    godot --headless --path /workspace --script res://tests/perf/headless_match_perf_run.gd -- \
    --ticks=3000 --warmup-ticks=200 --label="tree-$ao1_pair"
done
