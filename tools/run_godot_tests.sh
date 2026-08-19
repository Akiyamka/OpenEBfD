#!/usr/bin/env bash
set -uo pipefail

readonly SUITE_TIMEOUT_SECONDS="${GODOT_SUITE_TIMEOUT_SECONDS:-180}"
readonly GODOT_CONTAINER="${GODOT_CONTAINER:-./tools/godot-container}"
readonly PODMAN_BIN="${PODMAN_BIN:-podman}"

# The container gets a *longer* deadline than the outer `timeout` below, on
# purpose: `timeout` should normally be the one that fires and reports a
# suite as timed out, in the usual way our failure list already handles. The
# container's own --timeout (see GODOT_CONTAINER_TIMEOUT_SECONDS in
# tools/godot-container) is only the backstop that guarantees the container
# dies even when nothing is left on this side to signal it -- which is
# exactly the failure this script used to hit: `timeout` kills the local
# `podman run` client, but conmon and the container survive it and keep
# running, indefinitely, competing for the /workspace mount with every later
# suite. Deriving it from SUITE_TIMEOUT_SECONDS instead of hardcoding a
# second number keeps the two deadlines from drifting apart.
readonly CONTAINER_TIMEOUT_MARGIN_SECONDS=30
export GODOT_CONTAINER_TIMEOUT_SECONDS="${GODOT_CONTAINER_TIMEOUT_SECONDS:-$((SUITE_TIMEOUT_SECONDS + CONTAINER_TIMEOUT_MARGIN_SECONDS))}"

readonly SUITES=(
	tests/sim/match_clock_run.gd tests/sim/entity_registry_run.gd tests/sim/command_bus_run.gd
	tests/sim/command_codec_run.gd
	tests/characterization/run.gd tests/camera/run.gd tests/ui/cursor_run.gd
	tests/ui/side_panel_pagination_run.gd tests/audio/voice_feedback_run.gd
	tests/audio/movement_sounds_run.gd
	tests/buildings/run.gd tests/buildings/building_scene_catalog_run.gd tests/buildings/construction_sound_run.gd
	tests/buildings/placement_run.gd tests/buildings/wall_connectivity_run.gd
	tests/buildings/controller_run.gd tests/buildings/repair_run.gd tests/buildings/techtree_multiple_conyards_run.gd
	tests/buildings/primary_building_run.gd tests/buildings/upgrade_run.gd tests/buildings/building_death_run.gd tests/rules/run.gd
	tests/combat/bullet_rules_run.gd tests/combat/turret_mount_run.gd
	tests/combat/fire_sequence_run.gd
	tests/combat/deploy_fire_run.gd
	tests/combat/projectile_flight_run.gd
	tests/combat/muzzle_fx_run.gd
	tests/combat/impact_fx_run.gd
	tests/combat/shot_fx_composition_run.gd
	tests/combat/building_geometry_run.gd
	tests/combat/unit_fire_movement_run.gd
	tests/combat/unit_attack_order_run.gd
	tests/combat/defensive_building_run.gd
	tests/combat/death_category_run.gd
	tests/combat/multi_turret_run.gd
	tests/combat/authored_reload_sound_run.gd tests/match/unit_command_run.gd
	tests/units/deployment_run.gd tests/units/authored_deploy_sound_run.gd tests/units/unit_scene_catalog_run.gd
	tests/units/harvester_run.gd tests/units/flight_run.gd tests/units/advanced_carryall_run.gd
	tests/units/advanced_carryall_e2e_run.gd tests/units/death_strategy_run.gd
	tests/units/death_animation_run.gd tests/units/authored_death_voice_run.gd
	tests/effects/death_corpse_run.gd
	tests/match/demo_boot_run.gd tests/match/snapshot_run.gd tests/match/entity_id_run.gd
	tests/match/command_bus_wiring_run.gd tests/maps/run.gd
	tests/navigation/run.gd
	tests/net/loopback_run.gd
	tests/net/relay_run.gd
	tests/net/websocket_transport_run.gd
)

# Refuse to start on top of leftover containers rather than silently racing
# them for the /workspace bind mount. This is not a theoretical concern: a
# leaked container from a prior run competing for that mount is exactly what
# made tests/units/deployment_run.gd report 124 failures on a run that passed
# cleanly once the leaked containers were gone. A run that starts dirty
# produces results nobody should trust.
image="$("${GODOT_CONTAINER}" image)"
running="$("${PODMAN_BIN}" ps --filter "ancestor=${image}" --format '{{.ID}}  running {{.RunningFor}}  {{.Command}}')"
if [[ -n "${running}" ]]; then
	printf 'Refusing to start: containers from %s are already running:\n' "${image}" >&2
	printf '%s\n' "${running}" >&2
	printf '\nThese would compete with this run for the /workspace bind mount and can\n' >&2
	printf 'produce false failures. Stop them first, then re-run:\n' >&2
	printf '  podman kill %s\n' "$("${PODMAN_BIN}" ps --filter "ancestor=${image}" --format '{{.ID}}' | tr '\n' ' ')" >&2
	exit 1
fi

failures=()
for suite in "${SUITES[@]}"; do
	printf '\n=== %s ===\n' "${suite}"
	timeout --foreground "${SUITE_TIMEOUT_SECONDS}" \
		"${GODOT_CONTAINER}" godot --headless --path /workspace --script "res://${suite}"
	status=$?
	if (( status != 0 )); then
		failures+=("${suite} (${status})")
	fi
done

printf '\nGodot suites: %d passed, %d failed\n' \
	"$(( ${#SUITES[@]} - ${#failures[@]} ))" "${#failures[@]}"
if (( ${#failures[@]} > 0 )); then
	printf '  %s\n' "${failures[@]}"
	exit 1
fi
