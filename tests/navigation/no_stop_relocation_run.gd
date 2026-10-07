extends SceneTree

const NavigationSuiteScript := preload("res://tests/navigation/run.gd")
const NavigationSystemScript := preload("res://scripts/units/navigation/unit_navigation_system.gd")
const NavConstantsScript := preload("res://scripts/units/navigation/shared/nav_constants.gd")

var _assertions := 0
var _failures := 0


class FakeFlyer extends NavigationSuiteScript.FakeUnit:
	var airborne := true

	func _init() -> void:
		super()
		unit_definition.can_fly = true

	func flight_is_airborne_phase() -> bool:
		return airborne


func _initialize() -> void:
	await process_frame
	var grid := _make_grid()
	await _run(_test_idle_no_stop_unit_yields.bind(grid))
	await _run(_test_stoppable_unit_is_untouched.bind(grid))
	await _run(_test_stopped_commanded_unit_is_untouched.bind(grid))
	await _run(_test_held_unit_is_not_displaced.bind(grid))
	await _run(_test_no_candidate_leaves_unit_alone.bind(grid))
	await _run(_test_tie_uses_planner_order.bind(grid))
	await _run(_test_only_airborne_flyers_are_skipped.bind(grid))
	await _run(_test_blocker_refresh_starts_idle_parking.bind(grid))
	if _failures > 0:
		printerr("No-stop relocation tests: %d failures after %d assertions" % [_failures, _assertions])
		quit(1)
		return
	print("No-stop relocation tests: %d assertions passed" % _assertions)
	quit(0)


func _run(test: Callable) -> void:
	var assertions_before := _assertions
	test.call()
	if _assertions == assertions_before:
		_failures += 1
		printerr("FAIL: a case ended before asserting anything")
	await process_frame


func _test_idle_no_stop_unit_yields(grid: MapNavigationGrid) -> void:
	var navigation = _make_navigation(grid, "idle no-stop yield")
	var origin := Vector2i(128, 128)
	var unit := _make_unit(navigation, grid.grid_to_world(origin, true))
	var target := origin + Vector2i(4, -3)
	var no_stop := _no_stop_square(origin, NavConstantsScript.NO_STOP_SWEEP_RADIUS_CELLS)
	no_stop.erase(target)
	navigation.runtime_map.replace_blocked_cells({}, no_stop)
	navigation.blocker_tracker.sweep_idle_no_stop_agents()
	var agent := _agent(navigation, unit)
	var expected: Vector3 = grid.grid_to_world(target, true) - unit.simulation_position()
	expected.y = 0.0
	_expect(float(agent["yield_remaining"]) > 0.0, "an idle unit on a no-stop cell must be asked to yield")
	_expect(
		(agent["yield_direction"] as Vector3).dot(expected.normalized()) > 0.99,
		"the yield direction must point toward the nearest stoppable cell"
	)
	_dispose([navigation, unit])


func _test_stoppable_unit_is_untouched(grid: MapNavigationGrid) -> void:
	var navigation = _make_navigation(grid, "stoppable control")
	var unit := _make_unit(navigation, grid.grid_to_world(Vector2i(128, 128), true))
	navigation.blocker_tracker.sweep_idle_no_stop_agents()
	_expect(
		is_zero_approx(float(_agent(navigation, unit)["yield_remaining"])),
		"a unit on an ordinary stoppable cell must not yield"
	)
	_dispose([navigation, unit])


func _test_stopped_commanded_unit_is_untouched(grid: MapNavigationGrid) -> void:
	var navigation = _make_navigation(grid, "stopped commanded exclusion")
	var origin := Vector2i(128, 128)
	var unit := _make_unit(navigation, grid.grid_to_world(origin, true))
	navigation.command_move([unit], grid.grid_to_world(origin + Vector2i(6, 0), true))
	navigation.stop(unit)
	navigation.runtime_map.replace_blocked_cells({}, {origin: true})
	navigation.blocker_tracker.sweep_idle_no_stop_agents()
	_expect(
		is_zero_approx(float(_agent(navigation, unit)["yield_remaining"])),
		"a stopped unit with a retained command id must not be swept"
	)
	_dispose([navigation, unit])


func _test_held_unit_is_not_displaced(grid: MapNavigationGrid) -> void:
	var navigation = _make_navigation(grid, "hold delegation")
	var origin := Vector2i(128, 128)
	var unit := _make_unit(navigation, grid.grid_to_world(origin, true))
	navigation.set_hold_position(unit, true)
	navigation.runtime_map.replace_blocked_cells({}, {origin: true})
	navigation.blocker_tracker.sweep_idle_no_stop_agents()
	_expect(
		is_zero_approx(float(_agent(navigation, unit)["yield_remaining"])),
		"a held unit must be refused by request_yield()"
	)
	_dispose([navigation, unit])


func _test_no_candidate_leaves_unit_alone(grid: MapNavigationGrid) -> void:
	var navigation = _make_navigation(grid, "no candidate")
	var origin := Vector2i(128, 128)
	var unit := _make_unit(navigation, grid.grid_to_world(origin, true))
	navigation.runtime_map.replace_blocked_cells(
		{}, _no_stop_square(origin, NavConstantsScript.NO_STOP_SWEEP_RADIUS_CELLS)
	)
	navigation.blocker_tracker.sweep_idle_no_stop_agents()
	_expect(
		is_zero_approx(float(_agent(navigation, unit)["yield_remaining"])),
		"a no-stop unit with no nearby stoppable cell must be left alone"
	)
	_dispose([navigation, unit])


func _test_tie_uses_planner_order(grid: MapNavigationGrid) -> void:
	var navigation = _make_navigation(grid, "ring tie-break")
	var origin := Vector2i(128, 128)
	var unit := _make_unit(navigation, grid.grid_to_world(origin, true))
	var first := origin + Vector2i(-1, -1)
	var second := origin + Vector2i(1, -1)
	# This radius-2 fallback is deliberately non-collinear with `first`: a
	# reversed radius traversal must produce a different normalized direction.
	var farther := origin + Vector2i(-2, -1)
	var no_stop := _no_stop_square(origin, NavConstantsScript.NO_STOP_SWEEP_RADIUS_CELLS)
	no_stop.erase(first)
	no_stop.erase(second)
	no_stop.erase(farther)
	navigation.runtime_map.replace_blocked_cells({}, no_stop)
	navigation.blocker_tracker.sweep_idle_no_stop_agents()
	var expected: Vector3 = grid.grid_to_world(first, true) - unit.simulation_position()
	expected.y = 0.0
	_expect(
		(agent_direction(navigation, unit)).is_equal_approx(expected.normalized()),
		"equal-radius no-stop candidates must choose the planner's first horizontal-edge cell"
	)
	_dispose([navigation, unit])


func _test_only_airborne_flyers_are_skipped(grid: MapNavigationGrid) -> void:
	var navigation = _make_navigation(grid, "air and landed domains")
	var origin := Vector2i(128, 128)
	var flyer: Node3D = FakeFlyer.new()
	root.add_child(flyer)
	flyer.global_position = grid.grid_to_world(origin, true)
	navigation.register_unit(flyer)
	var target := origin + Vector2i(1, 0)
	var no_stop := _no_stop_square(origin, NavConstantsScript.NO_STOP_SWEEP_RADIUS_CELLS)
	no_stop.erase(target)
	navigation.runtime_map.replace_blocked_cells({}, no_stop)
	navigation.blocker_tracker.sweep_idle_no_stop_agents()
	var airborne_agent := _agent(navigation, flyer)
	_expect(
		is_zero_approx(float(airborne_agent["yield_remaining"])) \
			and (airborne_agent["yield_direction"] as Vector3).is_zero_approx(),
		"an airborne flyer must receive no ground-yield state"
	)
	flyer.airborne = false
	navigation.blocker_tracker.sweep_idle_no_stop_agents()
	_expect(
		float(_agent(navigation, flyer)["yield_remaining"]) > 0.0,
		"a landed flyer must be swept as a ground-domain agent"
	)
	_dispose([navigation, flyer])


func _test_blocker_refresh_starts_idle_parking(grid: MapNavigationGrid) -> void:
	var navigation = _make_navigation(grid, "blocker-refresh wiring")
	var origin := Vector2i(128, 128)
	var unit := _make_unit(navigation, grid.grid_to_world(origin, true))
	var building: Node3D = NavigationSuiteScript.FakeBuilding.new(["s"])
	building.set_meta(&"placement_anchor_cell", origin)
	building.add_to_group(&"sim_buildings")
	root.add_child(building)
	for _tick in range(16):
		navigation.sim_tick()
	var agent := _agent(navigation, unit)
	var destination_cell := grid.world_to_grid(agent["destination"] as Vector3)
	_expect(
		navigation.runtime_map.is_stoppable(
			destination_cell, int(agent["pass_mask"]), int(agent["clearance"]), int(agent["terrain_mask"])
		),
		"a blocker refresh must start idle parking that expires at a stoppable destination"
	)
	_dispose([navigation, unit, building])


func _make_navigation(grid: MapNavigationGrid, purpose: String):
	var navigation := NavigationSystemScript.new()
	root.add_child(navigation)
	if not navigation.setup(grid):
		push_error("navigation system must initialize for %s" % purpose)
	return navigation


func _make_unit(navigation, position: Vector3) -> Node3D:
	var unit: Node3D = NavigationSuiteScript.FakeUnit.new()
	root.add_child(unit)
	unit.global_position = position
	navigation.register_unit(unit)
	return unit


func _agent(navigation, unit: Node3D) -> Dictionary:
	return navigation._agents[unit.get_instance_id()]


func agent_direction(navigation, unit: Node3D) -> Vector3:
	return _agent(navigation, unit)["yield_direction"] as Vector3


func _no_stop_square(origin: Vector2i, radius: int) -> Dictionary:
	var cells := {}
	for y in range(-radius, radius + 1):
		for x in range(-radius, radius + 1):
			cells[origin + Vector2i(x, y)] = true
	return cells


func _dispose(nodes: Array) -> void:
	for node in nodes:
		node.queue_free()


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


func _expect(condition: bool, message: String) -> void:
	_assertions += 1
	if condition:
		return
	_failures += 1
	printerr("FAIL: %s" % message)
