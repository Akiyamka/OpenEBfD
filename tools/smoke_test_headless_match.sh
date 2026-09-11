#!/usr/bin/env bash
set -uo pipefail

readonly GODOT_CONTAINER="${GODOT_CONTAINER:-./tools/godot-container}"
readonly ENTRY_POINT="res://tools/run_headless_match.gd"

failures=()

run_scenario() {
	local name="$1"
	local expected_status="$2"
	local required_text="$3"
	local forbidden_text="$4"
	local second_forbidden_text="$5"
	shift 5
	local output
	local status
	output="$("${GODOT_CONTAINER}" godot --headless --path /workspace --script "${ENTRY_POINT}" -- "$@" 2>&1)"
	status=$?
	if (( status != expected_status )); then
		failures+=("${name}: expected exit ${expected_status}, got ${status}")
		printf 'FAIL: %s\n%s\n' "${name}" "${output}" >&2
		return
	fi
	if [[ -n "${required_text}" && "${output}" != *"${required_text}"* ]]; then
		failures+=("${name}: output did not contain ${required_text}")
		printf 'FAIL: %s\n%s\n' "${name}" "${output}" >&2
		return
	fi
	if [[ -n "${forbidden_text}" && "${output}" == *"${forbidden_text}"* ]]; then
		failures+=("${name}: output unexpectedly contained ${forbidden_text}")
		printf 'FAIL: %s\n%s\n' "${name}" "${output}" >&2
		return
	fi
	if [[ -n "${second_forbidden_text}" && "${output}" == *"${second_forbidden_text}"* ]]; then
		failures+=("${name}: output unexpectedly contained ${second_forbidden_text}")
		printf 'FAIL: %s\n%s\n' "${name}" "${output}" >&2
		return
	fi
	printf 'PASS: %s\n' "${name}"
}

run_scenario "missing --replay" 1 "--replay" "" ""
run_scenario "missing replay preflights before scene" 1 "--replay" "scene_path" "snapshot_digest" \
	--replay=res://tests/fixtures/does_not_exist_headless_smoke.oebr \
	--scene=res://tests/fixtures/does_not_exist_headless_smoke.tscn
run_scenario "default scene replay completes" 0 "" "" "" \
	--replay=res://tests/fixtures/headless_match_smoke.oebr
run_scenario "max-ticks bound fails" 1 "" "" "" \
	--replay=res://tests/fixtures/headless_match_smoke.oebr --max-ticks=10
run_scenario "alternate scene fails scene identity" 1 "scene_path" "" "" \
	--replay=res://tests/fixtures/headless_match_smoke.oebr \
	--scene=res://tests/fixtures/match_fixture.tscn

if (( ${#failures[@]} > 0 )); then
	printf 'Headless replay smoke: %d scenarios failed\n' "${#failures[@]}" >&2
	printf '  %s\n' "${failures[@]}" >&2
	exit 1
fi
printf 'Headless replay smoke: all five scenarios passed\n'
