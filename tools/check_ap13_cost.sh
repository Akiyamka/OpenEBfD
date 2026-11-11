#!/usr/bin/env bash
set -euo pipefail

ap13_tmp="$(mktemp -d /tmp/ap13-cost.XXXXXX)"
trap 'rm -rf "$ap13_tmp"' EXIT
git show HEAD:scripts/combat/projectile_unit_collision.gd > "$ap13_tmp/projectile_unit_collision.gd"
git show HEAD:scripts/combat/splash_unit_collision.gd > "$ap13_tmp/splash_unit_collision.gd"
ap13_sha="$(sha256sum "$ap13_tmp/projectile_unit_collision.gd" | cut -d' ' -f1)"
[[ "$ap13_sha" == "$(git show HEAD:scripts/combat/projectile_unit_collision.gd | sha256sum | cut -d' ' -f1)" ]]
[[ "$(sha256sum "$ap13_tmp/splash_unit_collision.gd" | cut -d' ' -f1)" == "$(git show HEAD:scripts/combat/splash_unit_collision.gd | sha256sum | cut -d' ' -f1)" ]]
ap13_image="$(./tools/godot-container image)"
ap13_mutation_mounts=()
if [[ "${AP13_MUTATION:-}" == no_prefilter ]]; then
  python3 - "$ap13_tmp/no_prefilter_collision.gd" <<'PY'
from pathlib import Path
import sys
source = Path("scripts/units/unit_authored_collision.gd").read_text()
assert source.count("if carried and _separated_by_plane") == 2
Path(sys.argv[1]).write_text(source.replace("if carried and _separated_by_plane", "if carried and false and _separated_by_plane"))
PY
  ap13_mutation_mounts=(--volume "$ap13_tmp/no_prefilter_collision.gd:/workspace/scripts/units/unit_authored_collision.gd:ro")
fi

ap13_run_set() {
  local ap13_set="$1"
  git status --untracked-files=all > "$ap13_tmp/$ap13_set.before"
  timeout --foreground 300 podman run --rm --userns=keep-id --security-opt label=disable \
    --timeout 270 --volume "$PWD:/workspace:ro" \
    --volume "$ap13_tmp/projectile_unit_collision.gd:/ap13_head/projectile_unit_collision.gd:ro" \
    --volume "$ap13_tmp/splash_unit_collision.gd:/ap13_head/splash_unit_collision.gd:ro" \
    "${ap13_mutation_mounts[@]}" \
    --workdir /workspace "$ap13_image" godot --headless --path /workspace \
    --script res://tests/perf/carried_target_cost_run.gd -- "--set=$ap13_set" \
    "--mutation=${AP13_MUTATION:-}" \
    > "$ap13_tmp/$ap13_set.log" 2>&1 || {
      cat "$ap13_tmp/$ap13_set.log" >&2
      exit 1
    }
  git status --untracked-files=all > "$ap13_tmp/$ap13_set.after"
  cmp "$ap13_tmp/$ap13_set.before" "$ap13_tmp/$ap13_set.after"
  grep '^AP13_STRESS_RESULT ' "$ap13_tmp/$ap13_set.log" || { cat "$ap13_tmp/$ap13_set.log" >&2; exit 1; }
  grep '^AP13_REALISTIC_RESULT ' "$ap13_tmp/$ap13_set.log" || { cat "$ap13_tmp/$ap13_set.log" >&2; exit 1; }
  if [[ -z "${AP13_MUTATION:-}" || "${AP13_MUTATION:-}" == scan ]]; then
    grep '^AP13_POPULATION_RESULT ' "$ap13_tmp/$ap13_set.log"
  fi
}
for ap13_set in warm sustained1 sustained2; do
  ap13_run_set "$ap13_set"
done

ap13_repeat="$(python3 - "$ap13_tmp" <<'PY'
import json
from pathlib import Path
import sys
root = Path(sys.argv[1])
split = False
for name in ("sustained1", "sustained2"):
    lines = (root / f"{name}.log").read_text().splitlines()
    stress = json.loads(next(s for s in lines if s.startswith("AP13_STRESS_RESULT ")).split(" ", 1)[1])
    realistic = json.loads(next(s for s in lines if s.startswith("AP13_REALISTIC_RESULT ")).split(" ", 1)[1])
    arms = realistic["arms"]
    delta = {k: [p["tree_us"] - p["head_us"] for p in v] for k, v in arms.items()}
    votes = [
        *[( [p["added_us"] for p in arm["pairs"]], 25000) for arm in stress["arrangements"].values()],
        (realistic["pass_sync_us"], 450),
        ([max(delta["direct_hit"][i], delta["direct_near"][i]) for i in range(7)], 30),
        ([max(delta[k][i] for k in ("sonic_hit", "graze_130", "graze_142", "graze_154", "sonic_near")) for i in range(7)], 50),
        (delta["sonic_near"], 35),
        ([max(delta["splash_hit"][i], delta["splash_gatefail"][i]) for i in range(7)], 30),
        (delta["aim"], 3),
        (realistic["e1_us"], 2000),
    ]
    split |= any(3 <= sum(v <= ceiling for v in values) <= 4 for values, ceiling in votes)
print("yes" if split else "no")
PY
)"
if [[ "$ap13_repeat" == yes ]]; then
  ap13_run_set repeat
fi

python3 - "$ap13_tmp" "${AP13_MUTATION:-}" <<'PY'
import json
from pathlib import Path
from statistics import median
import sys

root = Path(sys.argv[1])
failed = False
split = False
names = ("sustained1", "sustained2", "repeat") if (root / "repeat.log").exists() else ("sustained1", "sustained2")
for name in names:
    lines = (root / f"{name}.log").read_text().splitlines()
    line = next((line for line in lines if line.startswith("AP13_STRESS_RESULT ")), None)
    if line is None:
        raise SystemExit(f"{name}: no measured stress result")
    data = json.loads(line.removeprefix("AP13_STRESS_RESULT "))
    assert set(data["arrangements"]) == {"centre", "sonic_graze", "sonic_near", "direct_near"}
    for label, arm in data["arrangements"].items():
        assert arm["eligible_probes"] == 640
        assert arm["head_hits"] == arm["tree_hits"] == arm["expected_hits"]
        assert arm["expected_hits"] == (20 if label in ("centre", "sonic_graze") else 0)
        added = [pair["added_us"] for pair in arm["pairs"]]
        assert len(added) == 7
        ok = sum(value <= 25000 for value in added)
        print(f"{name} {label} measured added µs/tick: {added}; median {median(added):.1f}; <=25000: {ok}/7")
        if ok <= 2:
            failed = True
        elif ok <= 4 and (name == "repeat" or "repeat" not in names):
            split = True
    maxima = [max(arm["pairs"][i]["added_us"] for arm in data["arrangements"].values()) for i in range(7)]
    print(f"{name} stress maximum over arrangements: {maxima}; median {median(maxima):.1f} µs/tick")
    realistic_line = next((line for line in lines if line.startswith("AP13_REALISTIC_RESULT ")), None)
    if realistic_line is None:
        raise SystemExit(f"{name}: no realistic result")
    realistic = json.loads(realistic_line.removeprefix("AP13_REALISTIC_RESULT "))
    assert realistic["samples_per_pass_observation"] >= 200
    assert realistic["calls_per_arm_per_pair"] >= 2000
    assert realistic["aim_calls"] > 0
    arms = realistic["arms"]
    assert len(arms) == 10 and all(len(v) == 7 for v in arms.values())
    delta = {key: [p["tree_us"] - p["head_us"] for p in values] for key, values in arms.items()}
    gates = {
        "pass_sync": (realistic["pass_sync_us"], 450),
        "direct": ([max(delta["direct_hit"][i], delta["direct_near"][i]) for i in range(7)], 30),
        "sonic": ([max(delta[k][i] for k in ("sonic_hit", "graze_130", "graze_142", "graze_154", "sonic_near")) for i in range(7)], 50),
        "sonic_near": (delta["sonic_near"], 35),
        "splash": ([max(delta["splash_hit"][i], delta["splash_gatefail"][i]) for i in range(7)], 30),
        "aim": (delta["aim"], 3),
        "e1": (realistic["e1_us"], 2000),
    }
    for label, (values, ceiling) in gates.items():
        ok = sum(value <= ceiling for value in values)
        print(f"{name} {label}: {values}; median {median(values):.2f}; <={ceiling}: {ok}/7")
        if ok <= 2:
            failed = True
        elif ok <= 4 and (name == "repeat" or "repeat" not in names):
            split = True
    population_line = next((line for line in lines if line.startswith("AP13_POPULATION_RESULT ")), None)
    if population_line is not None:
        populations = json.loads(population_line.removeprefix("AP13_POPULATION_RESULT "))["results"]
        assert set(populations) == {"16", "50", "200", "1000"}
        for label in ("direct_hit", "direct_near", "sonic_hit", "graze_130", "graze_142", "graze_154", "sonic_near", "splash_hit", "splash_gatefail"):
            endpoint = []
            for i in range(7):
                low = populations["16"][label][i]
                high = populations["1000"][label][i]
                endpoint.append((high["tree_us"] - high["head_us"]) - (low["tree_us"] - low["head_us"]))
            slope = median(endpoint)
            mad = median(abs(value - slope) for value in endpoint)
            added = median(populations["1000"][label][i]["tree_us"] - populations["1000"][label][i]["head_us"] for i in range(7))
            bound = max(3 * mad, 10.0, 0.05 * abs(added))
            print(f"{name} population {label}: endpoint added slope {slope:.2f} µs; MAD {mad:.2f}; ceiling {bound:.2f}")
            if slope > bound:
                failed = True
    elif len(sys.argv) < 3 or sys.argv[2] in ("", "scan"):
        raise SystemExit(f"{name}: no population sweep")
if failed:
    raise SystemExit("AP13 cost gate exceeded an accepted ceiling; return measurements to human")
if split:
    raise SystemExit("AP13 cost INCONCLUSIVE after one repeat; return pair values to human")
PY
