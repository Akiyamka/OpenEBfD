#!/usr/bin/env bash
set -uo pipefail

readonly SUITE_TIMEOUT_SECONDS="${GODOT_SUITE_TIMEOUT_SECONDS:-180}"
readonly GODOT_CONTAINER="${GODOT_CONTAINER:-./tools/godot-container}"
readonly SUITES=(
	tests/characterization/run.gd tests/camera/run.gd tests/ui/cursor_run.gd
	tests/ui/side_panel_pagination_run.gd tests/audio/voice_feedback_run.gd
	tests/audio/movement_sounds_run.gd
	tests/buildings/run.gd tests/buildings/building_scene_catalog_run.gd tests/buildings/construction_sound_run.gd
	tests/buildings/placement_run.gd tests/buildings/wall_connectivity_run.gd
	tests/buildings/controller_run.gd tests/buildings/techtree_multiple_conyards_run.gd
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
	tests/match/demo_boot_run.gd tests/match/snapshot_run.gd tests/maps/run.gd
	tests/navigation/run.gd
	tests/net/loopback_run.gd
	tests/net/relay_run.gd
	tests/net/websocket_transport_run.gd
)

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
