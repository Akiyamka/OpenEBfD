#!/usr/bin/env bash
set -euo pipefail

repo="$(git rev-parse --show-toplevel)"
temp_dir="$(mktemp -d)"
trap 'rm -rf "$temp_dir"' EXIT
runtime=(
  scripts/match/match.gd
  scripts/match/sim_admission_queue.gd
  scripts/sim/entity_state.gd
  scripts/sim/entity_registry.gd
  scripts/world/map/spice_mound.gd
)
head_mounts=()
for path in "${runtime[@]}"; do
  mkdir -p "$temp_dir/$(dirname "$path")"
  git -C "$repo" show "HEAD:$path" > "$temp_dir/$path"
  head_mounts+=(--volume "$temp_dir/$path:/workspace/$path:ro")
done

run_arm() {
  local arm="$1"
  local -a mounts=()
  if [[ "$arm" == HEAD ]]; then
    mounts=("${head_mounts[@]}")
  fi
  podman run --rm --userns=keep-id --security-opt label=disable \
    --volume "$repo:/workspace:ro" "${mounts[@]}" \
    --workdir /workspace openebfd-godot:4.7 \
    godot --headless --path /workspace \
    --script res://tests/perf/persistent_unit_index_cost_run.gd -- --public-compare
}

results="$temp_dir/results.tsv"
for pair in 1 2 3; do
  printf 'AP26 pair %d HEAD\n' "$pair"
  run_arm HEAD > "$temp_dir/head-$pair.log" 2>&1
  grep 'AP26 public compare' "$temp_dir/head-$pair.log"
  printf 'AP26 pair %d tree\n' "$pair"
  run_arm tree > "$temp_dir/tree-$pair.log" 2>&1
  grep 'AP26 public compare' "$temp_dir/tree-$pair.log"
  read -r head_us head_span < <(sed -n 's/.*median_us=\([0-9.]*\) span_us=\([0-9.]*\).*/\1 \2/p' "$temp_dir/head-$pair.log")
  read -r tree_us tree_span < <(sed -n 's/.*median_us=\([0-9.]*\) span_us=\([0-9.]*\).*/\1 \2/p' "$temp_dir/tree-$pair.log")
  printf '%s %s %s %s\n' "$head_us" "$head_span" "$tree_us" "$tree_span" >> "$results"
done

python3 - "$results" <<'PY'
import sys
rows = [list(map(float, line.split())) for line in open(sys.argv[1])]
gaps = [tree - head for head, _, tree, _ in rows]
spreads = [max(head_span, tree_span) for _, head_span, _, tree_span in rows]
print('AP26 HEAD/tree gaps_us=', gaps, 'spreads_us=', spreads)
if any(gap > 1000 for gap in gaps):
    print('AP26 verdict: FAIL, realistic changed path exceeds 1 ms')
    sys.exit(2)
if all(gap > max(spread, 0.1 * head) for gap, spread, (head, _, _, _) in zip(gaps, spreads, rows)):
    print('AP26 verdict: FAIL, stable throughput regression')
    sys.exit(2)
if any(gap > spread for gap, spread in zip(gaps, spreads)):
    print('AP26 verdict: INCONCLUSIVE, median gap beyond spread; send to human')
    sys.exit(2)
print('AP26 verdict: INCONCLUSIVE, medians overlap spread; reviewer decides waiver')
sys.exit(1)
PY
