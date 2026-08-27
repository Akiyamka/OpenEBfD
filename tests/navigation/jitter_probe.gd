extends SceneTree
## Diagnostic probe (not part of the test suite): reproduces a harvester
## skirting a jagged diagonal terrain boundary and logs every steering stage
## per navigation tick, to find where left/right twitching enters the pipeline.

const NavigationSystemScript := preload("res://scripts/units/navigation/unit_navigation_system.gd")
const UnitDefinitionScript := preload("res://scripts/units/unit_definition.gd")
const MatchClockScript := preload("res://scripts/sim/match_clock.gd")


class ProbeUnit extends Node3D:
	var move_speed := 4.0
	var turn_rate := 0.15
	var can_move_any_direction := false
	var arrival_radius := 0.2
	var unit_definition := UnitDefinitionScript.new()
	var destination := Vector3.ZERO
	var is_selected := false
	var facing := Vector3.RIGHT
	var turn_starts := 0
	var commanded_headings: Array[Vector3] = []
	var _turning := false

	func _init() -> void:
		unit_definition.size = 3
		unit_definition.infantry = false
		unit_definition.can_fly = false
		unit_definition.terrain_ids = [&"Rock"]
		# Same reason tests/navigation/run.gd's FakeUnit joins here: slice
		# C6c's NavAgentRegistry.register_unit() gate refuses a node outside
		# "sim_units", and this probe registers through command_move() below.
		# This file is not in tools/run_godot_tests.sh's suite list, so no
		# suite would have caught it going stale.
		add_to_group(&"sim_units")

	## Slice R3: scripts/units/navigation/ground/* asks the agent's node where
	## it is through this duck-typed accessor rather than reading
	## global_position, so a stand-in that drives the real navigation system
	## has to answer it. Same reason this class joins "sim_units" above, and
	## the same trap: this file is not in tools/run_godot_tests.sh's suite
	## list, so no suite would have caught it going stale.
	func simulation_position() -> Vector3:
		return global_position

	func set_navigation_managed(_active: bool) -> void:
		pass

	func set_navigation_destination(value: Vector3) -> void:
		destination = value

	func prepare_navigation_order(_target: Vector3, _exit_point := Vector3.INF, _move_mode := 0) -> bool:
		return true

	func navigation_collision_radius(_fallback: float) -> float:
		return 2.179

	func navigation_rotation_radius(_fallback: float) -> float:
		return 3.393

	func facing_direction() -> Vector3:
		return facing

	func navigation_step(value: Vector3, delta: float) -> void:
		if value.length_squared() <= 0.000001:
			_turning = false
			return
		var target := value.normalized()
		commanded_headings.append(target)
		var difference := facing.signed_angle_to(target, Vector3.UP)
		var maximum_step := turn_rate * 20.0 * delta
		if absf(difference) > maximum_step + 0.000001:
			if not _turning:
				turn_starts += 1
			_turning = true
			facing = facing.rotated(
				Vector3.UP, clampf(difference, -maximum_step, maximum_step)
			).normalized()
			return
		_turning = false
		facing = target
		global_position += value * delta


func _initialize() -> void:
	await process_frame
	var grid := _make_grid()
	var navigation := NavigationSystemScript.new()
	root.add_child(navigation)
	if not navigation.setup(grid):
		printerr("PROBE: navigation setup failed")
		quit(1)
		return

	# Jagged diagonal boundary like the video's forbidden zone: the eastern
	# edge steps one cell west every two cells north (2:1 staircase).
	var walls := {}
	for y in range(80, 132):
		var edge := 96 - int((131 - y) / 2.0)
		for x in range(50, edge + 1):
			walls[Vector2i(x, y)] = true
	navigation.runtime_map.replace_blocked_cells(walls)

	var unit := ProbeUnit.new()
	root.add_child(unit)
	unit.global_position = Vector3(98.5, 0.0, 128.5)
	unit.facing = Vector3(0.0, 0.0, -1.0)
	var target := Vector3(64.5, 0.0, 74.5)
	navigation.command_move([unit], target)
	var agent: Dictionary = navigation._agents[unit.get_instance_id()]
	print("PROBE path=%s direct=%s dest=%.1f,%.1f radius=%.2f rot_radius=%.2f clearance=%d" % [
		str(agent["path"]), str(agent["direct_path"]),
		(agent["destination"] as Vector3).x, (agent["destination"] as Vector3).z,
		float(agent["radius"]), float(agent["rotation_radius"]), int(agent["clearance"]),
	])
	print("tick;pos_x;pos_z;facing_deg;desired_deg;pressure_deg;pressure_len;resolved_deg;resolved_len;stabil_deg;final_deg;pref_deg;pref_side;steer_dist;path_index;turn_in_place;moved")

	# 35 s of probe time, at the simulation tick rate rather than the old
	# hardcoded 20 Hz -- see the tick_count helpers in tests/navigation/run.gd
	# for the same conversion done for the real test suite.
	var delta := MatchClockScript.SECONDS_PER_TICK
	for tick in roundi(35.0 * float(MatchClockScript.TICKS_PER_SECOND)):
		# Probe every steering stage on shallow copies so the real agent state
		# is not advanced twice.
		var probe: Dictionary = agent.duplicate()
		var desired: Vector3 = navigation.call("_desired_velocity", probe)
		var pressure: Vector3 = navigation.avoidance.terrain_pressure(agent)
		var stage: Dictionary = agent.duplicate()
		var resolved_result: Dictionary = navigation.avoidance.resolve_velocity(
			stage, desired, delta, [agent], {}
		)
		var resolved: Vector3 = resolved_result["velocity"]
		var stage2: Dictionary = agent.duplicate()
		var stabilized: Vector3 = navigation.avoidance.stabilize_velocity(
			stage2, resolved, delta, [agent], {}
		)
		var preference_before: Vector3 = agent.get("avoidance_direction", Vector3.ZERO)
		var side_before := int(agent.get("avoidance_side", 0))
		var before := unit.global_position
		navigation.call("_navigation_tick")
		agent = navigation._agents[unit.get_instance_id()]
		var final := Vector3.ZERO
		if not unit.commanded_headings.is_empty():
			final = unit.commanded_headings.back()
		var steer: Vector3 = agent.get("steering_target", unit.global_position)
		var moved := unit.global_position.distance_to(before) > 0.001
		print("%d;%.3f;%.3f;%.1f;%.1f;%.1f;%.3f;%.1f;%.2f;%.1f;%.1f;%.1f;%d;%.2f;%d;%s;%s" % [
			tick,
			unit.global_position.x, unit.global_position.z,
			rad_to_deg(atan2(-unit.facing.x, -unit.facing.z)),
			_deg(desired),
			_deg(pressure), pressure.length(),
			_deg(resolved), resolved.length(),
			_deg(stabilized),
			_deg(final),
			_deg(preference_before), side_before,
			before.distance_to(steer),
			int(agent["path_index"]),
			str(bool(agent.get("steering_turn_in_place", false))),
			str(moved),
		])
		if unit.global_position.distance_to(agent["destination"]) < 1.0:
			print("PROBE arrived at tick %d" % tick)
			break

	var reversals := 0
	var previous_side := 0
	for index in range(1, unit.commanded_headings.size()):
		var change := unit.commanded_headings[index - 1].signed_angle_to(
			unit.commanded_headings[index], Vector3.UP
		)
		if absf(change) <= 0.01:
			continue
		var side := 1 if change > 0.0 else -1
		if previous_side != 0 and side != previous_side:
			reversals += 1
		previous_side = side
	print("PROBE summary: turn_starts=%d heading_reversals=%d headings=%d final_dist=%.2f" % [
		unit.turn_starts, reversals, unit.commanded_headings.size(),
		unit.global_position.distance_to(agent["destination"]),
	])
	quit(0)


func _deg(value: Vector3) -> float:
	if value.is_zero_approx():
		return NAN
	return rad_to_deg(atan2(-value.x, -value.z))


func _make_grid() -> MapNavigationGrid:
	var total := MapNavigationGrid.NAV_SIZE * MapNavigationGrid.NAV_SIZE
	var cpf := PackedInt32Array()
	var terrain := PackedInt32Array()
	var source_x := PackedInt32Array()
	var source_y := PackedInt32Array()
	var spice := PackedByteArray()
	var pass_mask := PackedInt32Array()
	var movement_cost := PackedFloat32Array()
	var buildable := PackedByteArray()
	for array in [cpf, terrain, source_x, source_y, spice, pass_mask, movement_cost, buildable]:
		array.resize(total)
	terrain.fill(MapNavigationGrid.TERRAIN_ROCK)
	pass_mask.fill(MapNavigationGrid.PASS_GROUND | MapNavigationGrid.PASS_AIR)
	movement_cost.fill(1.0)
	buildable.fill(1)
	var grid := MapNavigationGrid.new()
	grid.load_generated(
		"test", AABB(Vector3.ZERO, Vector3(256.0, 1.0, 256.0)), 1.0,
		cpf, terrain, source_x, source_y, spice, pass_mask, movement_cost, buildable, {}, {}
	)
	return grid
