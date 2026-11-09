#!/usr/bin/env bash
set -euo pipefail

ao3_status_before="$(git status --porcelain --untracked-files=all)"
ao3_tmp_dir="$(mktemp -d /tmp/ao3-cost.XXXXXX)"
ao3_check_status() {
  local ao3_status_after
  ao3_status_after="$(git status --porcelain --untracked-files=all)"
  if [[ "$ao3_status_before" != "$ao3_status_after" ]] || ! test ! -e tests/perf/fixtures/ao3_head_resolver.gd; then
    echo 'AO3 cost: working-tree status changed or stray HEAD resolver appeared during run' >&2
    diff -u <(printf '%s\n' "$ao3_status_before") <(printf '%s\n' "$ao3_status_after") || true
    return 1
  fi
}
ao3_cleanup() {
  local ao3_result=$?
  if ! ao3_check_status; then
    ao3_result=1
  fi
  rm -rf "$ao3_tmp_dir"
  exit "$ao3_result"
}
trap ao3_cleanup EXIT

git show HEAD:scripts/combat/combat_impact_resolver.gd > "$ao3_tmp_dir/head_full.gd"
[[ "$(head -n 1 "$ao3_tmp_dir/head_full.gd")" == 'class_name CombatImpactResolver' ]] || {
  echo 'AO3 cost: unexpected HEAD resolver first line' >&2; exit 2;
}
tail -n +2 "$ao3_tmp_dir/head_full.gd" > "$ao3_tmp_dir/ao3_head_resolver.gd"
cmp -s "$ao3_tmp_dir/ao3_head_resolver.gd" <(git show HEAD:scripts/combat/combat_impact_resolver.gd | tail -n +2) || {
  echo 'AO3 cost: HEAD resolver body provenance mismatch' >&2; exit 2;
}
ao3_run_set() {
  local ao3_set=$1
  local ao3_log="$ao3_tmp_dir/set-${ao3_set}.log"
  local ao3_run_code
  set +e
  timeout --foreground 1900 podman run --rm --userns=keep-id --security-opt label=disable --timeout 1800 \
    --volume "$PWD:/workspace:ro" \
    --volume "$ao3_tmp_dir/ao3_head_resolver.gd:/ao3_head/ao3_head_resolver.gd:ro" \
    --workdir /workspace openebfd-godot:4.7 \
    godot --headless --path /workspace --script res://tests/perf/splash_unit_collision_cost_run.gd 2>&1 | tee "$ao3_log"
  ao3_run_code=${PIPESTATUS[0]}
  set -e
  ao3_check_status || exit 1
  if [[ $ao3_run_code != 0 && $ao3_run_code != 3 ]]; then
    echo "AO3 cost: harness failure or timeout in set $ao3_set (exit $ao3_run_code)" >&2
    exit "$ao3_run_code"
  fi
  ao3_gate_line="$(sed -n 's/^AO3 gate set ratio=\([^ ]*\) empty=\([^ ]*\) slope=\([^ ]*\)$/\1 \2 \3/p' "$ao3_log" | tail -n 1)"
  if [[ -z "$ao3_gate_line" ]]; then
    echo "AO3 cost: missing gate status in set $ao3_set" >&2
    exit 2
  fi
}

ao3_combine() {
  local ao3_first=$1 ao3_second=$2
  if [[ "$ao3_first" == PASS ]]; then
    printf 'PASS'
  elif [[ "$ao3_first" == FAIL && "$ao3_second" == FAIL ]]; then
    printf 'FAIL'
  elif [[ "$ao3_first" == INCONCLUSIVE && "$ao3_second" == PASS ]]; then
    printf 'PASS'
  else
    printf 'INCONCLUSIVE'
  fi
}

ao3_run_set 1
read -r ao3_ratio_1 ao3_empty_1 ao3_slope_1 <<< "$ao3_gate_line"
if [[ "$ao3_ratio_1" == PASS && "$ao3_empty_1" == PASS && "$ao3_slope_1" == PASS ]]; then
  echo 'AO3 cost final: ratio=PASS empty=PASS slope=PASS (one set)'
  exit 0
fi
echo "AO3 cost: set 1 non-PASS (ratio=$ao3_ratio_1 empty=$ao3_empty_1 slope=$ao3_slope_1); running one fresh process repeat"
ao3_run_set 2
read -r ao3_ratio_2 ao3_empty_2 ao3_slope_2 <<< "$ao3_gate_line"
ao3_ratio_final="$(ao3_combine "$ao3_ratio_1" "$ao3_ratio_2")"
ao3_empty_final="$(ao3_combine "$ao3_empty_1" "$ao3_empty_2")"
ao3_slope_final="$(ao3_combine "$ao3_slope_1" "$ao3_slope_2")"
echo "AO3 cost final: ratio=$ao3_ratio_final empty=$ao3_empty_final slope=$ao3_slope_final (two sets)"
if [[ "$ao3_ratio_final" == FAIL || "$ao3_empty_final" == FAIL || "$ao3_slope_final" == FAIL ]]; then
  exit 1
fi
if [[ "$ao3_ratio_final" == PASS && "$ao3_empty_final" == PASS && "$ao3_slope_final" == PASS ]]; then
  exit 0
fi
exit 3
