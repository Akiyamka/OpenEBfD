#!/usr/bin/env bash
set -euo pipefail

case "${1:-}" in
  --public-calls|--match-ticks) ao2_mode="$1" ;;
  *) echo 'usage: tools/check_ao2_collision_cost.sh --public-calls|--match-ticks' >&2; exit 2 ;;
esac

if grep -n 'get_nodes_in_group' scripts/combat/projectile_unit_collision.gd scripts/combat/combat_projectile.gd; then
  echo 'AO2 cost audit: projectile path scans a scene-tree group' >&2
  exit 1
fi

ao2_tmp="$(mktemp -d /tmp/ao2-cost.XXXXXX)"
trap 'rm -rf "$ao2_tmp"' EXIT
mapfile -t ao2_runtime_files < <(git diff --diff-filter=M --name-only HEAD -- scripts/)
((${#ao2_runtime_files[@]})) || { echo 'AO2 cost audit: no changed runtime files' >&2; exit 2; }
ao2_head_mounts=()
for ao2_path in "${ao2_runtime_files[@]}"; do
  mkdir -p "$ao2_tmp/head/$(dirname "$ao2_path")"
  git show "HEAD:$ao2_path" > "$ao2_tmp/head/$ao2_path"
  ao2_head_mounts+=(--volume "$ao2_tmp/head/$ao2_path:/workspace/$ao2_path:ro")
done

ao2_image="$(./tools/godot-container image)"
for ao2_path in "${ao2_runtime_files[@]}"; do
  ao2_expected="$(sha256sum "$ao2_tmp/head/$ao2_path" | cut -d' ' -f1)"
  ao2_actual="$(podman run --rm --userns=keep-id --security-opt label=disable --entrypoint sha256sum \
    --volume "$PWD:/workspace:ro" "${ao2_head_mounts[@]}" --workdir /workspace \
    "$ao2_image" "/workspace/$ao2_path" | cut -d' ' -f1)"
  [[ "$ao2_expected" == "$ao2_actual" ]] || {
    echo "AO2 HEAD overlay SHA mismatch: $ao2_path" >&2
    exit 2
  }
done

ao2_run_arm() {
  local variant="$1" pair="$2"
  local -a mounts=()
  if [[ "$variant" == HEAD ]]; then mounts=("${ao2_head_mounts[@]}"); fi
  timeout --foreground 180 podman run --rm --userns=keep-id --security-opt label=disable \
    --timeout 150 --volume "$PWD:/workspace:ro" "${mounts[@]}" --workdir /workspace \
    "$ao2_image" godot --headless --path /workspace \
    --script res://tests/perf/projectile_unit_collision_cost_run.gd -- \
    "--label=$variant-$pair" --skip-population | tee "$ao2_tmp/$variant-$pair.log"
  grep -q '^AO2_COST_RESULT ' "$ao2_tmp/$variant-$pair.log" || {
    echo "AO2 cost result missing: $variant-$pair" >&2
    exit 2
  }
}

if [[ "$ao2_mode" == --public-calls ]]; then
  for ao2_pair in 1 2 3; do
    if ((ao2_pair % 2 == 0)); then
      ao2_run_arm tree "$ao2_pair"
      ao2_run_arm HEAD "$ao2_pair"
    else
      ao2_run_arm HEAD "$ao2_pair"
      ao2_run_arm tree "$ao2_pair"
    fi
  done

python3 - "$ao2_tmp" <<'PY'
import json
import pathlib
import statistics
import sys

root = pathlib.Path(sys.argv[1])
limits = {
    "empty_direct": 20.0,
    "ordos_direct": 30.0,
    "empty_sonic": 25.0,
    "ordos_graze": 75.0,
    "ordos_halo_miss": 75.0,
}
added = {name: [] for name in limits}
for pair in (1, 2, 3):
    result = {}
    for variant in ("HEAD", "tree"):
        lines = (root / f"{variant}-{pair}.log").read_text().splitlines()
        payload = next((line.removeprefix("AO2_COST_RESULT ") for line in lines
                        if line.startswith("AO2_COST_RESULT ")), None)
        if payload is None:
            raise SystemExit(f"AO2 missing result: {variant}-{pair}")
        result[variant] = json.loads(payload)
    tree = result["tree"]
    head = result["HEAD"]
    if tree["ap26_queries"] <= 0 or tree["ordos_probes"] <= 0 or tree["hull_copies"] != 0:
        raise SystemExit("AO2 tree workload did not query and probe cached hulls")
    if not all(head["results"][arm]["hit"] for arm in ("ordos_direct", "ordos_graze", "atreides_direct")):
        raise SystemExit("AO2 HEAD positive control did not hit")
    for name in limits:
        delta = tree["results"][name]["median_us"] - head["results"][name]["median_us"]
        added[name].append(delta)
        print(f"pair {pair} {name}: HEAD {head['results'][name]['median_us']:.3f} us, "
              f"tree {tree['results'][name]['median_us']:.3f} us, added {delta:.3f} us")
for name, limit in limits.items():
    median = statistics.median(added[name])
    spread = max(added[name]) - min(added[name])
    print(f"AO2 {name}: paired added median {median:.3f} us, span {spread:.3f} us, "
          f"provisional ceiling {limit:.1f} us")
print("AO2 Ordos direct provisional 30 us ceiling: accepted by the human; observed cost is not a measured PASS")
if any(min(added[name]) > limit for name, limit in limits.items() if name != "ordos_direct"):
    raise SystemExit("AO2 provisional per-call ceiling exceeded in every pair")
PY
  exit
fi

ao2_run_tick_arm() {
  local variant="$1" pair="$2" population="$3" shots="$4"
  local -a mounts=()
  if [[ "$variant" == HEAD ]]; then mounts=("${ao2_head_mounts[@]}"); fi
  local log="$ao2_tmp/tick-$variant-$pair-$population-$shots.log"
  timeout --foreground 180 podman run --rm --userns=keep-id --security-opt label=disable \
    --timeout 150 --volume "$PWD:/workspace:ro" "${mounts[@]}" --workdir /workspace \
    "$ao2_image" godot --headless --path /workspace \
    --script res://tests/perf/projectile_unit_collision_cost_run.gd -- \
    --mode=match-ticks "--population=$population" "--shots=$shots" \
    "--label=$variant-$pair-$population-$shots" > "$log" 2>&1
  grep '^AO2_TICK_RESULT ' "$log" || {
    cat "$log" >&2
    echo "AO2 Match tick result missing: $variant-$pair-$population-$shots" >&2
    exit 2
  }
}

echo "AO2 host load before Match tick pairs: $(cat /proc/loadavg)"
for ao2_pair in 1 2 3; do
  for ao2_workload in 16:2 200:2 1000:2 200:32; do
    IFS=: read -r ao2_population ao2_shots <<< "$ao2_workload"
    if ((ao2_pair % 2 == 0)); then
      ao2_run_tick_arm tree "$ao2_pair" "$ao2_population" "$ao2_shots"
      ao2_run_tick_arm HEAD "$ao2_pair" "$ao2_population" "$ao2_shots"
    else
      ao2_run_tick_arm HEAD "$ao2_pair" "$ao2_population" "$ao2_shots"
      ao2_run_tick_arm tree "$ao2_pair" "$ao2_population" "$ao2_shots"
    fi
  done
done
echo "AO2 host load after Match tick pairs: $(cat /proc/loadavg)"

python3 - "$ao2_tmp" <<'PY'
import json
import pathlib
import statistics
import sys

root = pathlib.Path(sys.argv[1])
failed = False
for population, shots in ((16, 2), (200, 2), (1000, 2), (200, 32)):
    added = []
    conclusive = []
    for pair in (1, 2, 3):
        arms = {}
        for variant in ("HEAD", "tree"):
            lines = (root / f"tick-{variant}-{pair}-{population}-{shots}.log").read_text().splitlines()
            line = next((s for s in lines if s.startswith("AO2_TICK_RESULT ")), None)
            if line is None:
                raise SystemExit(f"Missing result for {variant} {pair} {population}/{shots}")
            arms[variant] = json.loads(line.removeprefix("AO2_TICK_RESULT "))
        head, tree = arms["HEAD"], arms["tree"]
        if head["signatures"] != tree["signatures"]:
            raise SystemExit(f"HEAD/tree shot outcome mismatch for {population}/{shots} pair {pair}")
        if tree["seed_count"] != 1 or any(t["query_delta"] < shots or t["warm"] for t in tree["per_tick"]):
            raise SystemExit(f"AO2 workload precondition failed for {population}/{shots} pair {pair}")
        if any(t["warm"] for t in head["per_tick"]):
            raise SystemExit(f"AO1 snapshot warmed on HEAD for {population}/{shots} pair {pair}")
        delta = tree["median_us"] - head["median_us"]
        noise = max(head["iqr_us"], tree["iqr_us"])
        added.append(delta)
        conclusive.append(abs(delta) > noise)
        print(f"pair {pair} {population} Units/{shots} shots: HEAD {head['median_us']:.0f} us, "
              f"tree {tree['median_us']:.0f} us, added {delta:.0f} us, "
              f"same-arm IQR {noise:.0f} us, full spans {head['span_us']:.0f}/{tree['span_us']:.0f} us, "
              f"{'conclusive' if conclusive[-1] else 'INCONCLUSIVE'}")
    print(f"AO2 Match tick {population}/{shots}: paired added median {statistics.median(added):.0f} us, "
          f"range {min(added):.0f}..{max(added):.0f} us")
    if (population, shots) in ((200, 2), (1000, 2), (200, 32)):
        if min(added) > 1000 and sum(conclusive) >= 2:
            print(f"AO2 Match tick {population}/{shots}: stable >1 ms regression; STOP for human")
            failed = True
        elif min(added) > 1000:
            print(f"AO2 Match tick {population}/{shots}: >1 ms in all pairs but fewer than two clear noise; INCONCLUSIVE for reviewer")
            failed = True
        elif not any(conclusive):
            print(f"AO2 Match tick {population}/{shots}: all paired sets INCONCLUSIVE; STOP for human")
            failed = True
if failed:
    raise SystemExit(1)
PY
