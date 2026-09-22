extends SceneTree

## Measures simulation ticks per second for a populated demo match without
## frame-driven simulation. Run with:
##   godot --headless --path . --script res://tests/perf/headless_match_perf_run.gd -- --ticks=5000 --warmup-ticks=200
##
## User args (after `--`):
##   --ticks=N                     measured ticks (default 5000)
##   --warmup-ticks=N              discarded ticks before measuring (default 200)
##   --budget-ticks-per-second=F   fail when throughput is below F (default off)
##   --snapshot=PATH               building snapshot to restore
##   --out=PATH                    append the JSON result line to PATH
##   --label=TEXT                  free-form tag copied into the JSON result

const DEMO_MATCH_SCENE_PATH := "res://scenes/match/demo_match.tscn"
const DEFAULT_SNAPSHOT_PATH := "res://tests/perf/fixtures/demo_match_perf_snapshot.json"
const OR_APC_SCENE := preload("res://scenes/units/or_apc.tscn")
const NIAB_TANK_SCENE := preload("res://scenes/units/niab_tank.tscn")
const MatchSnapshotScript := preload("res://scripts/match/match_snapshot.gd")
const MatchClockScript := preload("res://scripts/sim/match_clock.gd")
const SimAttackCommandScript := preload("res://scripts/sim/commands/attack_command.gd")
const SimMoveCommandScript := preload("res://scripts/sim/commands/move_command.gd")
const TerrainProbeScript := preload("res://scripts/world/terrain_probe.gd")

const BOOT_SETTLE_FRAMES := 2
const EXPECTED_BUILDINGS := 49
const EXPECTED_UNITS := 16
const COMBAT_UNITS_PER_SIDE := 6
const NAVIGATION_UNITS := 4
const COMBAT_MIN_HP_LOST := 600.0
const COMBAT_ACTIVITY_WINDOW_TICKS := 100
const COMBAT_MIN_WINDOW_HP_LOST := 200.0
const PATROL_LEG_DISTANCE := 8.0
const PATROL_TURN_MARGIN_TICKS := 10
const PATROL_MIN_INTERVAL_DISTANCE := PATROL_LEG_DISTANCE * 0.5

var _ticks := 5000
var _warmup_ticks := 200
var _budget_ticks_per_second := 0.0
var _snapshot_path := DEFAULT_SNAPSHOT_PATH
var _out_path := ""
var _label := ""


func _initialize() -> void:
	_parse_args()
	var packed_scene := load(DEMO_MATCH_SCENE_PATH) as PackedScene
	if packed_scene == null:
		_fail("Cannot load demo match: %s" % DEMO_MATCH_SCENE_PATH)
		return
	var match_instance := packed_scene.instantiate()
	root.add_child(match_instance)
	match_instance.set_process(false)
	for _frame in BOOT_SETTLE_FRAMES:
		await process_frame
		match_instance.set_process(false)

	var restored := _restore_snapshot(match_instance)
	if not bool(restored.get("ok", false)):
		_fail("Headless perf snapshot restore failed: %s" % String(restored.get("message", "")))
		return

	var units_root := match_instance.get_node("Units") as Node3D
	var navigation_units := _spawn_navigation_units(match_instance, units_root)
	match_instance.advance_ticks(_warmup_ticks)
	_discard_warmup_units(units_root, navigation_units)

	var patrol_reissue_ticks := _patrol_reissue_ticks(navigation_units)
	if patrol_reissue_ticks <= 0:
		_fail("Headless perf navigation group has no usable move speed")
		return
	_submit_patrol(match_instance, navigation_units, true)

	var combat_units := _spawn_combat_units(match_instance, units_root)
	_disable_combat_presentation(combat_units)
	_submit_combat_orders(match_instance, combat_units)
	if not _has_expected_population(match_instance):
		return
	var population := _population_counts(match_instance)
	var entity_state = match_instance.entity_state()

	var measure_result := _measure_ticks(
		match_instance, units_root, navigation_units, combat_units,
		entity_state, patrol_reissue_ticks
	)
	if not bool(measure_result["ok"]):
		return
	var combat_hp_lost: float = measure_result["combat_hp_lost"]
	var combat_checks: Dictionary = measure_result["combat_checks"]
	var patrol_checks := _check_patrol_activity(measure_result["positions"])
	if combat_hp_lost < COMBAT_MIN_HP_LOST:
		_fail("Combat workload did not run: only %.1f HP/shields lost (need %.1f)" % [
			combat_hp_lost, COMBAT_MIN_HP_LOST
		])
		return
	if not bool(combat_checks["ok"]):
		_fail("Combat workload went idle: %d/%d combat windows confirmed" % [
			combat_checks["confirmed"], combat_checks["checked"]
		])
		return
	if not bool(patrol_checks["ok"]):
		_fail("Navigation workload did not run: %d/%d patrol intervals confirmed" % [
			patrol_checks["confirmed"], patrol_checks["checked"]
		])
		return

	var elapsed_usec: int = measure_result["elapsed_usec"]
	var ticks_per_second := float(_ticks) / maxf(float(elapsed_usec) / 1_000_000.0, 0.000001)
	var ok := _budget_ticks_per_second <= 0.0 or ticks_per_second >= _budget_ticks_per_second
	var result := {
		"ok": ok,
		"label": _label,
		"headless": DisplayServer.get_name() == "headless",
		"ticks": _ticks,
		"warmup_ticks": _warmup_ticks,
		"ticks_per_second": ticks_per_second,
		"budget_ticks_per_second": _budget_ticks_per_second,
		"buildings": population["buildings"],
		"units": population["units"],
		"combat_hp_lost": combat_hp_lost,
		"combat_windows_confirmed": combat_checks["confirmed"],
		"combat_windows_checked": combat_checks["checked"],
		"patrol_intervals_confirmed": patrol_checks["confirmed"],
		"patrol_intervals_checked": patrol_checks["checked"],
		"patrol_reissue_ticks": patrol_reissue_ticks,
		"restore": String(restored.get("message", "")),
	}
	_report(result)
	quit(0 if ok else 1)


func _parse_args() -> void:
	for arg in OS.get_cmdline_user_args():
		var parts := arg.split("=", true, 1)
		var key := parts[0]
		var value := parts[1] if parts.size() > 1 else ""
		match key:
			"--ticks":
				_ticks = maxi(int(value), 1)
			"--warmup-ticks":
				_warmup_ticks = maxi(int(value), 0)
			"--budget-ticks-per-second":
				_budget_ticks_per_second = maxf(float(value), 0.0)
			"--snapshot":
				_snapshot_path = value
			"--out":
				_out_path = value
			"--label":
				_label = value
			_:
				push_warning("Unknown headless perf argument: %s" % arg)


func _restore_snapshot(match_instance: Node) -> Dictionary:
	var snapshot = MatchSnapshotScript.new(_snapshot_path)
	return snapshot.restore(
		match_instance.get_node("Buildings") as Node3D,
		match_instance.get_node("Units") as Node3D
	)


func _spawn_navigation_units(match_instance: Node, units_root: Node3D) -> Array:
	var start := TerrainProbeScript.snap_to_ground(
		match_instance.get_world_3d(), Vector3(40.0, 0.0, 100.0)
	)
	var units: Array = []
	for _index in NAVIGATION_UNITS:
		var unit := NIAB_TANK_SCENE.instantiate()
		unit.owner_player_id = 1
		unit.position = start
		units_root.add_child(unit)
		unit.set_simulation_position(start)
		units.append(unit)
	return units


func _spawn_combat_units(match_instance: Node, units_root: Node3D) -> Array:
	var units: Array = []
	for index in COMBAT_UNITS_PER_SIDE * 2:
		units.append(_spawn_combat_unit(match_instance, units_root, index))
	return units


func _spawn_combat_unit(match_instance: Node, units_root: Node3D, index: int):
	var line_origin := Vector3(40.0, 0.0, 40.0 if index % 2 == 0 else 48.0)
	var position := TerrainProbeScript.snap_to_ground(match_instance.get_world_3d(), line_origin)
	position += Vector3(3.0 * (index / 2), 0.0, 0.0)
	var unit := OR_APC_SCENE.instantiate()
	unit.owner_player_id = 1 if index % 2 == 0 else 2
	unit.position = position
	units_root.add_child(unit)
	unit.set_simulation_position(position)
	return unit


## Muzzle flashes, projectile/impact visuals, and fire sounds do not feed the
## simulation. Leaving them on in a headless benchmark caused Godot to print a
## warning for each shot, making the measured rate depend on stderr's sink.
func _disable_combat_presentation(combat_units: Array) -> void:
	for unit in combat_units:
		for turret in unit.combat_turrets:
			turret.muzzle_flash_scene = null
			turret.projectile_visual_scene = null
			turret.impact_visual_scenes.clear()
			turret.fire_sound_paths.clear()


## The snapshot deliberately restores no units. Some restored buildings may
## emit a transient unit-owned node while their first ticks settle; discard it
## before the measured population is assembled so warmup cannot alter the
## fixed workload that this tool reports.
func _discard_warmup_units(units_root: Node3D, navigation_units: Array) -> void:
	for child in units_root.get_children():
		if child not in navigation_units:
			units_root.remove_child(child)
			child.free()


func _patrol_reissue_ticks(navigation_units: Array) -> int:
	if navigation_units.is_empty():
		return 0
	var speed := float(navigation_units[0].move_speed)
	if speed <= 0.0:
		return 0
	return ceili(PATROL_LEG_DISTANCE / speed * MatchClockScript.TICKS_PER_SECOND) \
		+ PATROL_TURN_MARGIN_TICKS


func _submit_patrol(match_instance: Node, navigation_units: Array, to_end: bool) -> void:
	var command := SimMoveCommandScript.new()
	command.player_id = 1
	var ids := PackedInt32Array()
	for unit in navigation_units:
		ids.append(int(unit.entity_id))
	command.entity_ids = ids
	command.target = Vector3(48.0, 0.0, 100.0) if to_end else Vector3(40.0, 0.0, 100.0)
	command.target = TerrainProbeScript.snap_to_ground(match_instance.get_world_3d(), command.target)
	match_instance._command_bus.submit(command, match_instance.next_orderable_tick())


## Idle units scan their forward arc but do not begin an attack order on their
## own. Submit mirrored attack orders through the same deferred command path as
## the patrol so every unit has a live combat target during the measured batch.
func _submit_combat_orders(match_instance: Node, combat_units: Array) -> void:
	for index in range(0, combat_units.size(), 2):
		_submit_attack(match_instance, combat_units[index], combat_units[index + 1])
		_submit_attack(match_instance, combat_units[index + 1], combat_units[index])


func _submit_attack(match_instance: Node, attacker, target) -> void:
	var command := SimAttackCommandScript.new()
	command.player_id = int(attacker.owner_player_id)
	command.entity_ids = PackedInt32Array([int(attacker.entity_id)])
	command.target_entity_id = int(target.entity_id)
	command.target = target.simulation_position()
	match_instance._command_bus.submit(command, match_instance.next_orderable_tick())


func _has_expected_population(match_instance: Node) -> bool:
	var population := _population_counts(match_instance)
	var buildings: int = population["buildings"]
	var units: int = population["units"]
	if buildings == EXPECTED_BUILDINGS and units == EXPECTED_UNITS:
		return true
	_fail("Headless perf population mismatch: %d buildings, %d units (need %d, %d)" % [
		buildings, units, EXPECTED_BUILDINGS, EXPECTED_UNITS
	])
	return false


func _population_counts(match_instance: Node) -> Dictionary:
	return {
		"buildings": (match_instance.get_node("Buildings") as Node).get_child_count(),
		"units": (match_instance.get_node("Units") as Node).get_child_count(),
	}


func _combat_hp(entity_state, combat_units: Array) -> float:
	var total := 0.0
	for unit in combat_units:
		var id := int(unit.entity_id)
		if entity_state.has_health(id):
			total += entity_state.health(id)
		if entity_state.has_shields(id):
			total += entity_state.shields(id)
	return total


func _measure_ticks(
		match_instance: Node,
		units_root: Node3D,
		navigation_units: Array,
		combat_units: Array,
		entity_state,
		patrol_reissue_ticks: int
	) -> Dictionary:
	var remaining := _ticks
	var target_is_end := true
	var positions: Array = []
	var combat_chunk_losses: Array[float] = []
	var start_usec := Time.get_ticks_usec()
	while remaining > 0:
		var chunk_ticks := mini(patrol_reissue_ticks, remaining)
		var combat_hp_before := _combat_hp(entity_state, combat_units)
		match_instance.advance_ticks(chunk_ticks)
		var combat_hp_after := _combat_hp(entity_state, combat_units)
		combat_chunk_losses.append(maxf(combat_hp_before - combat_hp_after, 0.0))
		remaining -= chunk_ticks
		positions.append(_navigation_positions(navigation_units))
		if remaining > 0 and not _replace_defeated_combat_units(
			match_instance, units_root, combat_units, entity_state
		):
			return {"ok": false}
		if remaining > 0:
			target_is_end = not target_is_end
			_submit_patrol(match_instance, navigation_units, target_is_end)
	var elapsed_usec := Time.get_ticks_usec() - start_usec
	var combat_checks := _check_combat_activity(combat_chunk_losses, patrol_reissue_ticks)
	return {
		"ok": true,
		"elapsed_usec": elapsed_usec,
		"positions": positions,
		"combat_hp_lost": _sum_float_array(combat_chunk_losses),
		"combat_checks": combat_checks,
	}


## A 6v6 ORAPC engagement naturally resolves in a few hundred ticks. Replace
## only defeated participants between measurement chunks, preserving the fixed
## 16-unit population while keeping later chunks a real combat workload too.
func _replace_defeated_combat_units(
		match_instance: Node,
		units_root: Node3D,
		combat_units: Array,
		entity_state
	) -> bool:
	var replaced := false
	for index in combat_units.size():
		var unit = combat_units[index]
		if is_instance_valid(unit) and entity_state.has_health(int(unit.entity_id)):
			continue
		if is_instance_valid(unit):
			units_root.remove_child(unit)
			unit.free()
		combat_units[index] = _spawn_combat_unit(match_instance, units_root, index)
		replaced = true
	if not replaced:
		return true
	_disable_combat_presentation(combat_units)
	_submit_combat_orders(match_instance, combat_units)
	return _has_expected_combat_group(units_root, combat_units)


## Projectiles are also children of Units while in flight, so the root's child
## count is only a valid population proof before the first measured shot. The
## replacement path instead verifies the twelve live participant nodes it owns.
func _has_expected_combat_group(units_root: Node3D, combat_units: Array) -> bool:
	var live := 0
	for unit in combat_units:
		if is_instance_valid(unit) and unit.get_parent() == units_root:
			live += 1
	if live == COMBAT_UNITS_PER_SIDE * 2:
		return true
	_fail("Headless perf combat group mismatch: %d units (need %d)" % [
		live, COMBAT_UNITS_PER_SIDE * 2
	])
	return false


## Four 27-tick patrol chunks cover at least 100 ticks, comfortably spanning
## the ORAPC's 50-tick reload. Every full window must record a real hit; this
## catches a battle that resolves early and leaves most of a long run idle.
func _check_combat_activity(chunk_losses: Array[float], patrol_reissue_ticks: int) -> Dictionary:
	var chunks_per_window := maxi(
		ceili(float(COMBAT_ACTIVITY_WINDOW_TICKS) / float(patrol_reissue_ticks)), 1
	)
	var checked := chunk_losses.size() / chunks_per_window
	var confirmed := 0
	for window_index in checked:
		var start := window_index * chunks_per_window
		var end := start + chunks_per_window
		if _sum_float_array(chunk_losses.slice(start, end)) >= COMBAT_MIN_WINDOW_HP_LOST:
			confirmed += 1
	return {"ok": checked > 0 and confirmed == checked, "confirmed": confirmed, "checked": checked}


func _sum_float_array(values: Array[float]) -> float:
	var total := 0.0
	for value in values:
		total += value
	return total


func _navigation_positions(navigation_units: Array) -> Array:
	var positions: Array = []
	for unit in navigation_units:
		positions.append(unit.simulation_position())
	return positions


func _check_patrol_activity(positions: Array) -> Dictionary:
	var checked := maxi(positions.size() - 2, 0)
	var confirmed := 0
	for index in range(1, positions.size() - 1):
		var previous: Array = positions[index - 1]
		var current: Array = positions[index]
		var all_moved := true
		for unit_index in current.size():
			if (current[unit_index] as Vector3).distance_to(previous[unit_index] as Vector3) \
			< PATROL_MIN_INTERVAL_DISTANCE:
				all_moved = false
				break
		if all_moved:
			confirmed += 1
	return {"ok": confirmed >= checked, "confirmed": confirmed, "checked": checked}


func _report(result: Dictionary) -> void:
	print("--- headless match tick perf ---")
	print("label:      %s" % result["label"])
	print("population: %d buildings, %d units" % [result["buildings"], result["units"]])
	print("workload:   %.1f combat HP/shields lost; %d/%d combat windows; %d/%d patrol intervals" % [
		result["combat_hp_lost"], result["combat_windows_confirmed"],
		result["combat_windows_checked"], result["patrol_intervals_confirmed"],
		result["patrol_intervals_checked"]
	])
	print("ticks:      %d measured after %d warmup" % [result["ticks"], result["warmup_ticks"]])
	print("throughput: %.1f ticks/s (real time: %d ticks/s)" % [
		result["ticks_per_second"], MatchClockScript.TICKS_PER_SECOND
	])
	if result["budget_ticks_per_second"] > 0.0:
		print("budget:     %.1f ticks/s -> %s" % [
			result["budget_ticks_per_second"], "PASS" if bool(result["ok"]) else "FAIL"
		])
	var json_line := JSON.stringify(result)
	print("json:       %s" % json_line)
	_append_result(json_line)


func _append_result(json_line: String) -> void:
	if _out_path.is_empty():
		return
	var file := FileAccess.open(_out_path, FileAccess.READ_WRITE) \
		if FileAccess.file_exists(_out_path) else FileAccess.open(_out_path, FileAccess.WRITE)
	if file == null:
		push_error("Cannot write perf result to %s" % _out_path)
		return
	file.seek_end()
	file.store_line(json_line)
	file.close()


func _fail(message: String) -> void:
	printerr(message)
	quit(1)
