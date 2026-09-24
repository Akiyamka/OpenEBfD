#!/usr/bin/env bash
set -uo pipefail

readonly GODOT_CONTAINER="${GODOT_CONTAINER:-./tools/godot-container}"
readonly ENTRY_POINT="res://tools/run_native_replay_hash.gd"
readonly NATIVE_REPLAY_SCENE="${NATIVE_REPLAY_SCENE:-res://scenes/dev/web_replay_check_ticks.tscn}"


extract_single_hash() {
	local side="$1"
	local output="$2"
	local pattern="$3"
	local -a matches=()

	mapfile -t matches < <(grep -oP "${pattern}" <<<"${output}")
	if (( ${#matches[@]} != 1 )); then
		printf 'FAIL: %s side produced %d hash marker(s), expected exactly one. Raw output:\n%s\n' \
			"${side}" "${#matches[@]}" "${output}" >&2
		return 1
	fi
	printf '%s\n' "${matches[0]}"
}


native_output="$("${GODOT_CONTAINER}" godot --headless --path /workspace --script "${ENTRY_POINT}" -- \
	--scene="${NATIVE_REPLAY_SCENE}" 2>&1)"
native_status=$?
printf '%s\n' "${native_output}"
if (( native_status != 0 )); then
	printf 'FAIL: native replay run failed with exit %d.\n' "${native_status}" >&2
	exit "${native_status}"
fi

native_hash="$(extract_single_hash "native" "${native_output}" 'NATIVE_REPLAY_HASH ticks=\d+ hash=\K\d+')"
native_hash_status=$?
if (( native_hash_status != 0 )); then
	exit 1
fi

if [[ -v WEB_REPLAY_HASH_OVERRIDE ]]; then
	web_hash="${WEB_REPLAY_HASH_OVERRIDE}"
	printf 'Using WEB_REPLAY_HASH_OVERRIDE=%s\n' "${web_hash}"
else
	web_output="$(make godot-web-replay-ticks-check 2>&1)"
	web_status=$?
	printf '%s\n' "${web_output}"
	if (( web_status != 0 )); then
		printf 'FAIL: web replay run failed with exit %d.\n' "${web_status}" >&2
		exit "${web_status}"
	fi
	web_hash="$(extract_single_hash "web" "${web_output}" 'WEB_REPLAY_CHECK_RESULT.*\bhash=\K\d+')"
	web_hash_status=$?
	if (( web_hash_status != 0 )); then
		exit 1
	fi
fi

printf 'Native replay hash: %s\n' "${native_hash}"
printf 'Web replay hash: %s\n' "${web_hash}"
if [[ "${native_hash}" == "${web_hash}" ]]; then
	printf 'PASS: native and web replay hashes match (native=%s web=%s)\n' "${native_hash}" "${web_hash}"
	exit 0
fi

printf 'FAIL: native and web replay hashes differ (native=%s web=%s)\n' "${native_hash}" "${web_hash}" >&2
exit 1
