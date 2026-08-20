extends SceneTree

const NavigationMapScript := preload("res://scripts/units/navigation/unit_navigation_map.gd")
const NavigationPlannerScript := preload("res://scripts/units/navigation/unit_navigation_planner.gd")
const NavigationSystemScript := preload("res://scripts/units/navigation/unit_navigation_system.gd")
const NavConstantsScript := preload("res://scripts/units/navigation/shared/nav_constants.gd")
const MatchClockScript := preload("res://scripts/sim/match_clock.gd")
const BuildingFootprintScript := preload("res://scripts/buildings/building_footprint.gd")
const UnitDefinitionScript := preload("res://scripts/units/unit_definition.gd")
const BuildingDefinitionScript := preload("res://scripts/buildings/building_definition.gd")
const UnitScene := preload("res://scenes/units/unit.tscn")
const ATKindjalModelScene := preload(
	"res://assets/converted/models/AT_Kindjal_H0/AT_Kindjal_H0.scn"
)

var _assertions := 0
var _failures := 0


class FakeUnit extends Node3D:
	var move_speed := 6.0
	var turn_rate := 0.15
	var navigation_radius_override := -1.0
	var navigation_rotation_radius_override := -1.0
	var can_move_any_direction := true
	var arrival_radius := 0.2
	var unit_definition := UnitDefinitionScript.new()
	var managed := false
	var destination := Vector3.ZERO
	var owner_player_id := 1
	var is_selected := false
	var defer_navigation_orders := false
	var prepared_navigation_targets: Array[Vector3] = []
	var attack_arc_direction := Vector3.ZERO

	func _init(size := 1.0, infantry := false) -> void:
		unit_definition.size = roundi(size)
		unit_definition.infantry = infantry
		unit_definition.can_fly = false
		unit_definition.terrain_ids = [&"Rock"]

	func set_navigation_managed(active: bool) -> void:
		managed = active

	func set_navigation_destination(value: Vector3) -> void:
		destination = value

	func set_selected(value: bool) -> void:
		is_selected = value

	func navigation_collision_radius(fallback: float) -> float:
		return navigation_radius_override if navigation_radius_override > 0.0 else fallback

	func navigation_rotation_radius(fallback: float) -> float:
		return navigation_rotation_radius_override \
			if navigation_rotation_radius_override > 0.0 else fallback

	func prepare_navigation_order(target: Vector3, _exit_point := Vector3.INF, _move_mode := 0) -> bool:
		prepared_navigation_targets.append(target)
		return not defer_navigation_orders

	func navigation_step(value: Vector3, delta: float) -> void:
		global_position += value * delta

	func is_enemy_of(player_id: int) -> bool:
		return owner_player_id != player_id

	func set_attack_arc_direction(value: Vector3) -> void:
		attack_arc_direction = value


class FakeTurningUnit extends FakeUnit:
	var facing := Vector3.RIGHT
	var turn_starts := 0
	var commanded_headings: Array[Vector3] = []
	var _turning := false

	func _init(size := 1.0, infantry := false) -> void:
		super(size, infantry)
		can_move_any_direction = false

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


## Duck-typed stand-in for a landed CanFly unit (see Unit.move_to/flight_is_landed):
## only implements the flight-facing surface command_move's takeoff redirect
## checks, not a real UnitFlightController.
class FakeLandedFlyer extends FakeUnit:
	var landed := true
	var move_to_calls: Array[Vector3] = []

	func _init(size := 1.0) -> void:
		super(size, false)
		unit_definition.can_fly = true

	func flight_is_landed() -> bool:
		return landed

	func move_to(world_position: Vector3, _exit_point := Vector3.INF) -> void:
		move_to_calls.append(world_position)
		landed = false


class FakeAirborneUnit extends FakeUnit:
	func combat_is_airborne() -> bool:
		return true


class FakeBuilding extends Node3D:
	var building_definition := BuildingDefinitionScript.new()

	func _init(rows: Array[String]) -> void:
		building_definition.occupy_rows = rows


## Ticks needed to cover `seconds` of simulated time at MatchClock's rate.
## Every duration below used to be a hardcoded iteration count against the
## navigation system's own 20 Hz tick (0.05 s/tick); now that
## UnitNavigationSystem.sim_tick() runs on the one simulation tick, this is
## the single place that conversion happens, so the next MatchClock rate
## change updates every call site through here instead of needing another
## sweep of the 61 that used to hardcode it.
func _navigation_tick_count(seconds: float) -> int:
	return roundi(seconds * float(MatchClockScript.TICKS_PER_SECOND))


## Advances `navigation` by `seconds` of simulated time, one _navigation_tick()
## call per fixed simulation tick.
func _advance_navigation(navigation, seconds: float) -> void:
	for _iteration in _navigation_tick_count(seconds):
		navigation.call("_navigation_tick")


func _initialize() -> void:
	await process_frame
	var grid := _make_grid()
	_test_synchronous_paths(grid)
	_test_no_stop_cells(grid)
	_test_unit_navigation_order_api(grid)
	_test_disconnected_island_orders(grid)
	await _test_transport_drop_probe_uses_destination_not_reachability(grid)
	_test_distributed_targets_avoid_disconnected_island(grid)
	_test_group_move_redirects_landed_flyer(grid)
	_test_dock_order_has_per_unit_building_access(grid)
	_test_building_marker_navigation_semantics(grid)
	_test_map_change_prunes_freed_units(grid)
	_test_blocker_change_reroutes_direct_path_agent(grid)
	_test_blocked_target_uses_unit_approach_side(grid)
	_test_rotated_building_blockers(grid)
	_test_interior_escape(grid)
	_test_immediate_movement(grid)
	_test_fast_unit_does_not_overshoot_near_destination(grid)
	_test_selected_unit_navigation_debug(grid)
	_test_rounded_local_avoidance_field(grid)
	_test_local_avoidance_preserves_route_half_plane(grid)
	_test_continuous_corner_steering(grid)
	_test_long_steering_arc_does_not_periodically_stop(grid)
	_test_far_target_large_bearing_starts_driven_arc(grid)
	_test_close_target_does_not_become_orbit(grid)
	_test_path_lookahead_smooths_waypoint_corner(grid)
	_test_path_chord_uses_rounded_geometry(grid)
	_test_missed_waypoint_advances_through_route_gate(grid)
	_test_large_unit_steers_smoothly_around_corner(grid)
	_test_jagged_boundary_steering_stays_smooth(grid)
	_test_slots_and_collision(grid)
	_test_destination_uses_body_geometry(grid)
	_test_approach_anchor_prefers_nearest_valid_block(grid)
	_test_slide_around_stopped_friend(grid)
	_test_turning_unit_arcs_around_stopped_friend(grid)
	_test_turn_in_place_counts_as_blocked_and_triggers_yield(grid)
	_test_squeeze_does_not_ram_adjacent_friend(grid)
	_test_group_convergence(grid)
	_test_group_rounds_sharp_corner(grid)
	_test_bunched_group_reverses_at_corner(grid)
	_test_dense_group_rounds_solid_region(grid)
	_test_large_pair_keeps_lanes_at_shared_corner(grid)
	_test_yield_behaviour(grid)
	_test_command_overrides_yield(grid)
	_test_grid_aligned_slots(grid)
	_test_lane_through_standing_formation(grid)
	_test_overlap_is_squeezed_out(grid)
	_test_hold_position_resists_separation(grid)
	_test_firing_anchor_resists_separation(grid)
	_test_attack_arc_spreads_a_group(grid)
	_test_firing_position_follows_its_arc_slot(grid)
	_test_combat_deployed_unit_resists_displacement(grid)
	_test_large_overlap_spans_spatial_buckets(grid)
	_test_enemy_stays_solid_under_separation(grid)
	_test_elastic_corridor_pass(grid)
	_test_large_reciprocal_crossing(grid)
	_test_circle_convergence_metrics(grid)
	_test_group_shift_keeps_shape(grid)
	if _failures > 0:
		printerr("Unit navigation tests: %d failures after %d assertions" % [_failures, _assertions])
		quit(1)
		return
	print("Unit navigation tests: %d assertions passed" % _assertions)
	quit(0)


func _test_unit_navigation_order_api(grid: MapNavigationGrid) -> void:
	var navigation := NavigationSystemScript.new()
	root.add_child(navigation)
	_expect(navigation.setup(grid), "navigation system must initialize for the unit order API")
	var unit := FakeUnit.new()
	root.add_child(unit)
	unit.global_position = Vector3(90.5, 0.0, 100.5)
	var blocked_target := Vector3(110.5, 0.0, 100.5)
	navigation.runtime_map.replace_blocked_cells({grid.world_to_grid(blocked_target): true})
	_expect(
		navigation.can_move_to([unit], Vector3(100.5, 0.0, 100.5)),
		"movement cursor query must accept an exact stoppable destination"
	)
	_expect(
		not navigation.can_move_to([unit], blocked_target),
		"movement cursor query must reject an exact blocked destination"
	)
	_expect(
		unit.prepared_navigation_targets.is_empty() and unit.destination == Vector3.ZERO,
		"movement cursor queries must not prepare or mutate a unit order"
	)
	unit.defer_navigation_orders = true
	var target := Vector3(100.5, 0.0, 100.5)
	var deferred := navigation.command_move([unit], target)
	_expect(deferred.is_empty(), "a unit must be able to defer a route before navigation mutates its agent")
	_expect(unit.prepared_navigation_targets == [target], "navigation must pass the assigned destination through the unit API")
	_advance_navigation(navigation, 1.0)
	_expect(unit.global_position == Vector3(90.5, 0.0, 100.5), "a deferred navigation order must not move the unit")

	unit.defer_navigation_orders = false
	var accepted := navigation.command_move([unit], target)
	_expect(accepted.size() == 1, "the same unit must be able to accept a later route")
	_advance_navigation(navigation, 5.0)
	_expect(unit.global_position.distance_to(target) < 1.0, "an accepted route must move after unit preparation")

	navigation.queue_free()
	unit.queue_free()


func _test_disconnected_island_orders(grid: MapNavigationGrid) -> void:
	var navigation := NavigationSystemScript.new()
	root.add_child(navigation)
	_expect(navigation.setup(grid), "navigation system must initialize for island reachability")
	var wall := {}
	for y in MapNavigationGrid.NAV_SIZE:
		wall[Vector2i(128, y)] = true
	navigation.runtime_map.replace_blocked_cells(wall)

	var stranded := FakeUnit.new()
	root.add_child(stranded)
	stranded.global_position = Vector3(100.5, 0.0, 100.5)
	var unreachable_target := Vector3(150.5, 0.0, 100.5)
	_expect(
		not navigation.can_move_to([stranded], unreachable_target),
		"a legal cell on another navigation island must be rejected by the cursor query"
	)
	var rejected := navigation.command_move([stranded], unreachable_target)
	_expect(rejected.is_empty(), "a unit must not receive an order to another navigation island")
	_expect(
		stranded.prepared_navigation_targets.is_empty(),
		"an unreachable island order must be rejected before it mutates the unit action"
	)
	_advance_navigation(navigation, 5.0)
	_expect(
		stranded.global_position == Vector3(100.5, 0.0, 100.5),
		"a rejected island order must not make the unit walk into the separating wall"
	)
	var firing_position := navigation.reachable_attack_position(
		stranded, unreachable_target, 30.0
	)
	_expect(
		firing_position.is_finite()
		and Vector2(
			firing_position.x - unreachable_target.x,
			firing_position.z - unreachable_target.z
		).length() <= 30.0,
		"attack pursuit must find a reachable firing cell inside weapon range"
	)
	var obstructed_radius := 20.0
	var line_of_fire_position := navigation.reachable_attack_position(
		stranded, unreachable_target, 30.0,
		func(candidate: Vector3) -> bool:
			return Vector2(
				candidate.x - unreachable_target.x,
				candidate.z - unreachable_target.z
			).length() >= obstructed_radius
	)
	_expect(
		line_of_fire_position.is_finite()
		and Vector2(
			line_of_fire_position.x - unreachable_target.x,
			line_of_fire_position.z - unreachable_target.z
		).length() >= obstructed_radius,
		"a perch the weapon could not fire from must be skipped for one that can"
	)
	var firing_move := navigation.command_move([stranded], firing_position)
	_expect(
		firing_move.size() == 1,
		"the navigation-selected firing cell must be accepted from the unit's island"
	)

	var reachable := FakeUnit.new()
	root.add_child(reachable)
	reachable.global_position = Vector3(145.5, 0.0, 100.5)
	var mixed := navigation.command_move([stranded, reachable], unreachable_target)
	_expect(
		mixed.size() == 1 and (mixed[0]["unit"] as Node3D) == reachable,
		"a mixed-island group order must retain only units connected to the target"
	)
	_advance_navigation(navigation, 5.0)
	_expect(
		reachable.global_position.distance_to(unreachable_target) < 1.0,
		"the reachable member of a mixed-island group must still execute the order"
	)

	navigation.queue_free()
	stranded.queue_free()
	reachable.queue_free()


func _test_transport_drop_probe_uses_destination_not_reachability(grid: MapNavigationGrid) -> void:
	var navigation := NavigationSystemScript.new()
	root.add_child(navigation)
	_expect(navigation.setup(grid), "navigation must initialize for transport drop footprint probe")
	var wall := {}
	for y in MapNavigationGrid.NAV_SIZE:
		wall[Vector2i(128, y)] = true
	navigation.runtime_map.replace_blocked_cells(wall)
	var cargo := FakeUnit.new()
	cargo.add_to_group("units")
	root.add_child(cargo)
	cargo.global_position = Vector3(100.5, 0.0, 100.5)
	var destination := Vector3(150.5, 0.0, 100.5)
	_expect(
		navigation.can_place_transport_cargo(cargo, destination),
		"carryall drop must accept a legal destination across a disconnected island"
	)
	var ground_blocker := FakeUnit.new()
	ground_blocker.add_to_group("units")
	root.add_child(ground_blocker)
	ground_blocker.global_position = destination
	_expect(
		not navigation.can_place_transport_cargo(cargo, destination),
		"ground footprint occupancy must reject an otherwise legal drop"
	)
	_expect(
		navigation.can_place_transport_cargo(cargo, destination, ground_blocker),
		"the carrying transport itself must be ignored by its destination occupancy probe"
	)
	ground_blocker.queue_free()
	await process_frame
	var airborne_blocker := FakeAirborneUnit.new()
	airborne_blocker.add_to_group("units")
	root.add_child(airborne_blocker)
	airborne_blocker.global_position = destination
	_expect(
		navigation.can_place_transport_cargo(cargo, destination),
		"airborne units must not occupy ground cargo footprint space"
	)
	navigation.runtime_map.replace_blocked_cells(wall, {grid.world_to_grid(destination): true})
	_expect(
		not navigation.can_place_transport_cargo(cargo, destination),
		"cargo may not be unloaded onto a traversable no-stop apron"
	)
	cargo.queue_free()
	airborne_blocker.queue_free()
	navigation.queue_free()


func _test_distributed_targets_avoid_disconnected_island(grid: MapNavigationGrid) -> void:
	var navigation := NavigationSystemScript.new()
	root.add_child(navigation)
	_expect(navigation.setup(grid), "navigation system must initialize for distributed island targets")
	# The clicked cell at (120, 100) is reachable, but the compact group's
	# shape-preserving +2-cell aim lands on the isolated cell at (122, 100).
	var island := Vector2i(122, 100)
	navigation.runtime_map.replace_blocked_cells({
		island + Vector2i.LEFT: true,
		island + Vector2i.RIGHT: true,
		island + Vector2i.UP: true,
		island + Vector2i.DOWN: true,
	})
	var units: Array[FakeUnit] = []
	for x in [100.5, 102.5, 104.5, 106.5]:
		var unit := FakeUnit.new()
		root.add_child(unit)
		unit.global_position = Vector3(x, 0.0, 100.5)
		units.append(unit)
	var target := Vector3(120.5, 0.0, 100.5)
	var assignments := navigation.command_move(units, target)
	_expect(assignments.size() == units.size(), "a reachable group order must retain every unit")
	for assignment in assignments:
		var unit: Node3D = assignment["unit"]
		var assigned_cell: Vector2i = grid.world_to_grid(assignment["position"])
		_expect(
			assigned_cell != island,
			"automatic endpoint distribution must not assign an enclosed island"
		)
		_expect(
			not bool(navigation.agent_debug(unit).get("route_unreachable", false)),
			"every automatically distributed endpoint must be reachable"
		)

	navigation.queue_free()
	for unit in units:
		unit.queue_free()


## Group orders reach the facade through UnitNavigationSystem.command_move
## directly (command controllers call it, not Unit.move_to()), so a landed
## flyer swept into the selection never got the takeoff redirect that
## move_to() applies for a single-unit order. command_move must peel it off
## and redirect it through move_to() itself, leaving the rest of the group
## routed normally.
func _test_group_move_redirects_landed_flyer(grid: MapNavigationGrid) -> void:
	var navigation := NavigationSystemScript.new()
	root.add_child(navigation)
	_expect(navigation.setup(grid), "navigation system must initialize for the mixed-domain group order test")

	var flyer := FakeLandedFlyer.new()
	root.add_child(flyer)
	flyer.global_position = Vector3(90.5, 0.0, 100.5)
	var ground_unit := FakeUnit.new()
	root.add_child(ground_unit)
	ground_unit.global_position = Vector3(92.5, 0.0, 100.5)

	var target := Vector3(100.5, 0.0, 100.5)
	var assignments := navigation.command_move([flyer, ground_unit], target)

	_expect(flyer.move_to_calls.size() == 1 and flyer.move_to_calls[0] == target,
		"a landed flyer swept into a group order must be redirected through move_to (takeoff) instead of routed")
	_expect(not flyer.landed, "the redirect must actually begin the flyer's takeoff")
	_expect(assignments.size() == 1 and (assignments[0]["unit"] as Node3D) == ground_unit,
		"only the ground unit receives a slot assignment from the same group order")

	_advance_navigation(navigation, 5.0)
	_expect(ground_unit.global_position.distance_to(target) < 1.0,
		"the ground unit in the mixed group must still move normally")

	navigation.queue_free()
	flyer.queue_free()
	ground_unit.queue_free()


func _test_synchronous_paths(grid: MapNavigationGrid) -> void:
	var runtime_map := NavigationMapScript.new()
	_expect(runtime_map.setup(grid), "runtime map must accept a loaded baked grid")
	_expect(runtime_map.replace_blocked_cells(_wall_cells()), "dynamic walls must increment the map revision")

	var planner := NavigationPlannerScript.new()
	planner.setup(runtime_map)
	var rock_mask := 1 << MapNavigationGrid.TERRAIN_ROCK

	var cold_start := Time.get_ticks_usec()
	planner.prewarm(MapNavigationGrid.PASS_VEHICLE, 0, rock_mask)
	var cold_ms := float(Time.get_ticks_usec() - cold_start) / 1000.0
	var warm_start := Time.get_ticks_usec()
	var path: Array[Vector2i] = planner.find_path(
		Vector2i(20, 128), Vector2i(40, 100), MapNavigationGrid.PASS_VEHICLE, 0, rock_mask
	)
	var warm_ms := float(Time.get_ticks_usec() - warm_start) / 1000.0
	print("Navigation benchmark: profile bake %.2f ms, detour path %.2f ms" % [cold_ms, warm_ms])
	# 250 ms, not the 50 ms this used to be. The bake measures around 50 ms on
	# a development machine (47-53 across a dozen observed runs), so a 50 ms
	# bound sat exactly on top of its own measurement and failed on roughly
	# half of all runs -- load shifted the coin, it did not flip it. A guard
	# that red-lights half the time is worse than no guard: it teaches whoever
	# reads the suite to skip past this line, and the honest failures next to
	# it lose their meaning too. What this is actually for is catching a
	# regression in kind -- a bake that turns into a visible stall during map
	# load -- not a few milliseconds of drift, so the bound belongs where a
	# stall starts being perceptible. Its sibling below is the shape to copy:
	# warm_ms measures 0.12-0.17 ms against a 5 ms bound, and never argues.
	_expect(cold_ms < 250.0, "the one-off profile bake must stay within a loading hitch")
	_expect(warm_ms < 5.0, "a detour path must compute within one frame")
	_expect(not path.is_empty() and path[path.size() - 1] == Vector2i(40, 100), "synchronous A* must find an indirect route")
	var crossed_opening := false
	for path_cell in path:
		if path_cell.x == 30 and path_cell.y >= 126 and path_cell.y <= 130:
			crossed_opening = true
	_expect(crossed_opening, "synchronous A* must route through the wall opening")

	var narrow: Array[Vector2i] = planner.find_path(
		Vector2i(55, 128), Vector2i(70, 128), MapNavigationGrid.PASS_VEHICLE, 0, rock_mask
	)
	_expect(not narrow.is_empty() and narrow[narrow.size() - 1] == Vector2i(70, 128), "a single-cell gap must pass clearance zero")
	var wide: Array[Vector2i] = planner.find_path(
		Vector2i(55, 128), Vector2i(70, 128), MapNavigationGrid.PASS_VEHICLE, 1, rock_mask
	)
	_expect(not wide.is_empty() and wide[wide.size() - 1].x < 60, "clearance one must stop before a single-cell gap and go as close as possible")


func _test_no_stop_cells(grid: MapNavigationGrid) -> void:
	var apron := {}
	for y in range(100, 108):
		for x in range(100, 108):
			apron[Vector2i(x, y)] = true

	var runtime_map := NavigationMapScript.new()
	runtime_map.setup(grid)
	_expect(runtime_map.replace_blocked_cells({}, apron), "a no-stop overlay must increment the map revision")
	_expect(runtime_map.is_passable(Vector2i(103, 103), MapNavigationGrid.PASS_VEHICLE), "no-stop cells must stay traversable")
	_expect(not runtime_map.is_stoppable(Vector2i(103, 103), MapNavigationGrid.PASS_VEHICLE), "no-stop cells must not be valid stops")

	var planner := NavigationPlannerScript.new()
	planner.setup(runtime_map)
	var rock_mask := 1 << MapNavigationGrid.TERRAIN_ROCK
	var exit_path: Array[Vector2i] = planner.find_path(
		Vector2i(103, 103), Vector2i(103, 120), MapNavigationGrid.PASS_VEHICLE, 0, rock_mask
	)
	_expect(
		not exit_path.is_empty() and exit_path[0] == Vector2i(103, 103) and exit_path.back() == Vector2i(103, 120),
		"a route may start on and leave a no-stop cell normally"
	)
	var through: Array[Vector2i] = planner.find_path(
		Vector2i(103, 95), Vector2i(103, 112), MapNavigationGrid.PASS_VEHICLE, 0, rock_mask
	)
	var crossed_apron := false
	for path_cell in through:
		crossed_apron = crossed_apron or apron.has(path_cell)
	_expect(not through.is_empty() and through.back() == Vector2i(103, 112) and crossed_apron, "routes must freely cross a no-stop apron")
	var into_apron: Array[Vector2i] = planner.find_path(
		Vector2i(103, 120), Vector2i(103, 103), MapNavigationGrid.PASS_VEHICLE, 0, rock_mask
	)
	_expect(not into_apron.is_empty() and not apron.has(into_apron[into_apron.size() - 1]), "a destination on the apron must snap to the nearest stoppable cell")
	var explicit_into_apron: Array[Vector2i] = planner.find_path(
		Vector2i(103, 120), Vector2i(103, 103), MapNavigationGrid.PASS_VEHICLE, 0, rock_mask,
		{Vector2i(103, 103): true}
	)
	_expect(
		not explicit_into_apron.is_empty() and explicit_into_apron.back() == Vector2i(103, 103),
		"an explicit no-stop command leg must be able to end on its selected cell"
	)


	var navigation := NavigationSystemScript.new()
	root.add_child(navigation)
	_expect(navigation.setup(grid), "navigation system must initialize")
	navigation.runtime_map.replace_blocked_cells({}, apron)
	var passer := FakeUnit.new()
	root.add_child(passer)
	passer.global_position = Vector3(103.5, 0.0, 95.5)
	navigation.command_move([passer], Vector3(103.5, 0.0, 112.5), NavConstantsScript.MoveMode.FREE)
	_advance_navigation(navigation, 5.0)
	_expect(passer.global_position.distance_to(Vector3(103.5, 0.0, 112.5)) < 2.0, "local steering must drive straight through a no-stop apron")

	var clicker := FakeUnit.new()
	root.add_child(clicker)
	clicker.global_position = Vector3(103.5, 0.0, 120.5)
	var assignments := navigation.command_move([clicker], Vector3(103.5, 0.0, 103.5), NavConstantsScript.MoveMode.FREE)
	var slot_cell: Vector2i = grid.world_to_grid(assignments[0]["position"])
	_expect(apron.has(slot_cell), "an explicit movement order must retain its selected no-stop destination")
	_expect(bool(navigation.agent_debug(clicker)["no_stop_destination"]), "the no-stop leg must retain access to its explicit destination")
	var command_count := navigation.command_log().size()
	var entered_apron := false
	for _iteration in _navigation_tick_count(10.0):
		navigation.call("_navigation_tick")
		entered_apron = entered_apron or apron.has(grid.world_to_grid(clicker.global_position))
	var parked_cell: Vector2i = grid.world_to_grid(navigation.agent_debug(clicker)["destination"])
	_expect(entered_apron, "the unit must enter the ordered no-stop area")
	_expect(
		apron.has(parked_cell) and clicker.global_position.distance_to(navigation.agent_debug(clicker)["destination"]) < 1.0,
		"arrival on no-stop space must leave the unit stopped at its ordered destination"
	)
	_expect(
		navigation.command_log().size() == command_count,
		"arrival on no-stop space must not create an automatic evacuation order"
	)

	var produced := FakeUnit.new()
	root.add_child(produced)
	produced.global_position = Vector3(103.5, 0.0, 103.5)
	navigation.command_move([produced], Vector3(103.5, 0.0, 120.5), NavConstantsScript.MoveMode.FREE)
	_expect(bool(navigation.agent_debug(produced)["route_ready"]), "a unit inside the apron must still get a route immediately")
	_advance_navigation(navigation, 10.0)
	_expect(produced.global_position.distance_to(Vector3(103.5, 0.0, 120.5)) < 2.0, "a unit produced inside the apron must walk out and reach its destination")

	navigation.queue_free()
	passer.queue_free()
	clicker.queue_free()
	produced.queue_free()


func _test_dock_order_has_per_unit_building_access(grid: MapNavigationGrid) -> void:
	var navigation := NavigationSystemScript.new()
	root.add_child(navigation)
	_expect(navigation.setup(grid), "navigation system must initialize for docking")
	var building_body := {}
	var dock_cells := {}
	for y in range(100, 108):
		for x in range(100, 108):
			var cell := Vector2i(x, y)
			if x >= 103 and x <= 105 and y >= 103:
				dock_cells[cell] = true
			else:
				building_body[cell] = true
	for y in range(108, 112):
		for x in range(103, 106):
			dock_cells[Vector2i(x, y)] = true
	navigation.runtime_map.replace_blocked_cells(building_body, dock_cells)

	var harvester := FakeUnit.new(3.0)
	root.add_child(harvester)
	harvester.global_position = Vector3(96.5, 0.0, 104.5)
	var dock := Vector3(104.5, 0.0, 104.5)
	_expect(navigation.command_dock(harvester, dock, dock_cells), "a reserved harvester must receive a d/p stopping exception")
	_expect(navigation.arrival_tolerance(harvester) > 0.35, "a size-three harvester must use its larger navigation arrival tolerance")
	var crossed_building_body := false
	for _iteration in _navigation_tick_count(10.0):
		navigation.call("_navigation_tick")
		crossed_building_body = crossed_building_body or building_body.has(
			grid.world_to_grid(harvester.global_position)
		)
	_expect(harvester.global_position.distance_to(dock) < 0.6, "the docking harvester must enter and stop on d/p cells")
	_expect(not crossed_building_body, "a docking route from the side must go around b cells")
	var second_harvester := FakeUnit.new(3.0)
	root.add_child(second_harvester)
	second_harvester.global_position = Vector3(104.5, 0.0, 108.5)
	var departure_target := Vector3(120.5, 0.0, 104.5)
	_expect(
		navigation.command_depart(harvester, departure_target, dock_cells) \
		and navigation.command_depart(second_harvester, departure_target, dock_cells) \
		and bool(navigation.agent_debug(harvester)["departure_access"]),
		"departing harvesters must temporarily retain access to their refinery cells"
	)
	_advance_navigation(navigation, 10.0)
	var first_destination: Vector3 = navigation.agent_debug(harvester)["destination"]
	var second_destination: Vector3 = navigation.agent_debug(second_harvester)["destination"]
	_expect(
		harvester.global_position.distance_to(first_destination) < 1.0 \
		and second_harvester.global_position.distance_to(second_destination) < 1.0 \
		and first_destination.distance_to(second_destination) > 1.0 \
		and not bool(navigation.agent_debug(harvester)["departure_access"]) \
		and not bool(navigation.agent_debug(second_harvester)["departure_access"]),
		"departures must claim separate normal parking blocks and drop refinery access after exiting"
	)

	var ordinary := FakeUnit.new()
	root.add_child(ordinary)
	ordinary.global_position = Vector3(110.5, 0.0, 103.5)
	var assignments := navigation.command_move([ordinary], dock)
	var ordinary_cell: Vector2i = grid.world_to_grid(assignments[0]["position"])
	_expect(
		dock_cells.has(ordinary_cell) and bool(navigation.agent_debug(ordinary)["no_stop_destination"]),
		"an ordinary order may enter and remain on the same d/p cells"
	)

	navigation.queue_free()
	harvester.queue_free()
	second_harvester.queue_free()
	ordinary.queue_free()


func _test_building_marker_navigation_semantics(grid: MapNavigationGrid) -> void:
	var match_root := Node3D.new()
	root.add_child(match_root)
	var building := FakeBuilding.new(["BDPS"])
	building.position = Vector3(100.0, 0.0, 100.0)
	building.add_to_group("buildings")
	match_root.add_child(building)
	var navigation := NavigationSystemScript.new()
	match_root.add_child(navigation)
	_expect(navigation.setup(grid), "navigation must initialize for occupy marker semantics")
	navigation.call("_refresh_building_blockers")
	var footprint: Dictionary = BuildingFootprintScript.nav_cells_by_marker(
		building, building.building_definition.occupy_rows, grid, 2
	)
	for cell in footprint:
		var marker := String(footprint[cell]).to_lower()
		if marker == "b":
			_expect(navigation.runtime_map.is_blocked(cell), "b occupy cells must remain solid")
		else:
			_expect(
				navigation.runtime_map.is_passable(cell, MapNavigationGrid.PASS_VEHICLE)
					and not navigation.runtime_map.is_stoppable(cell, MapNavigationGrid.PASS_VEHICLE),
				"s/d/p occupy cells must be passable no-stop space"
			)
	match_root.free()


func _test_map_change_prunes_freed_units(grid: MapNavigationGrid) -> void:
	var match_root := Node3D.new()
	root.add_child(match_root)
	var navigation := NavigationSystemScript.new()
	match_root.add_child(navigation)
	_expect(navigation.setup(grid), "navigation must initialize for freed-unit blocker refresh")
	var unit := FakeUnit.new()
	match_root.add_child(unit)
	unit.global_position = Vector3(90.5, 0.0, 100.5)
	navigation.command_move([unit], Vector3(120.5, 0.0, 100.5))
	var unit_id := unit.get_instance_id()
	unit.free()

	var building := FakeBuilding.new(["B"])
	building.position = Vector3(100.0, 0.0, 100.0)
	building.add_to_group("buildings")
	match_root.add_child(building)
	navigation.call("_refresh_building_blockers")
	_expect(
		not navigation._agents.has(unit_id),
		"a blocker-map replan must prune agents whose units were already freed"
	)
	match_root.free()


## Regression guard: a commanded agent whose order resolves to a clear
## straight line (`direct_path == true`) has no stored A* corridor to diff a
## blocker change against. If a wall drops squarely across that direct line
## after the order was issued, the diff-based reroute filter must still
## notice (by re-checking line-of-sight, not by consulting the — necessarily
## empty — corridor) and queue the agent for a real replan, instead of
## leaving it steering forever at a straight-line target it can no longer
## reach.
func _test_blocker_change_reroutes_direct_path_agent(grid: MapNavigationGrid) -> void:
	var navigation := NavigationSystemScript.new()
	root.add_child(navigation)
	_expect(navigation.setup(grid), "navigation must initialize for the direct-path reroute regression test")

	var unit := FakeUnit.new()
	root.add_child(unit)
	unit.global_position = Vector3(40.5, 0.0, 40.5)
	var destination := Vector3(80.5, 0.0, 40.5)
	navigation.command_move([unit], destination)
	var agent: Dictionary = navigation._agents[unit.get_instance_id()]
	_expect(
		bool(agent["direct_path"]),
		"an open-field order must resolve to a direct line before the wall exists"
	)

	# A wall dropped squarely across the straight line: thick enough that the
	# unit can no longer cross it, but narrow along y so a route around either
	# end still exists in the open field.
	var wall := {}
	for x in range(58, 62):
		for y in range(20, 60):
			wall[Vector2i(x, y)] = true
	_expect(
		navigation.runtime_map.replace_blocked_cells(wall),
		"the wall must register as a blocked-cell change"
	)
	navigation.call("_replan_after_map_change")
	navigation.call("_navigation_tick")

	agent = navigation._agents[unit.get_instance_id()]
	_expect(
		not bool(agent["direct_path"]),
		"a wall crossing the stored direct line must be detected and clear the stale direct-path flag"
	)

	_advance_navigation(navigation, 20.0)
	_expect(
		unit.global_position.distance_to(destination) < 2.0,
		"the unit must route around the new wall instead of stalling against its stale direct line"
	)

	navigation.queue_free()
	unit.queue_free()


func _test_blocked_target_uses_unit_approach_side(grid: MapNavigationGrid) -> void:
	var navigation := NavigationSystemScript.new()
	root.add_child(navigation)
	_expect(navigation.setup(grid), "navigation must initialize for blocked target approach selection")
	var building_body := {}
	for y in range(100, 108):
		for x in range(100, 108):
			building_body[Vector2i(x, y)] = true
	navigation.runtime_map.replace_blocked_cells(building_body)
	var target := Vector3(103.5, 0.0, 103.5)

	var front_unit := FakeUnit.new(3.0)
	root.add_child(front_unit)
	front_unit.global_position = Vector3(103.5, 0.0, 114.5)
	var front_assignment := navigation.command_move([front_unit], target)[0] as Dictionary
	var front_destination: Vector3 = front_assignment["position"]
	_expect(
		front_destination.z > 108.0 and absf(front_destination.x - target.x) < 2.0,
		"a unit already in front of a blocked target must approach on the front side (got %.1f, %.1f)" % [
			front_destination.x, front_destination.z
		]
	)

	var left_unit := FakeUnit.new(3.0)
	root.add_child(left_unit)
	left_unit.global_position = Vector3(90.5, 0.0, 103.5)
	var left_assignment := navigation.command_move([left_unit], target)[0] as Dictionary
	var left_destination: Vector3 = left_assignment["position"]
	_expect(
		left_destination.x < 99.5 and absf(left_destination.z - target.z) < 2.0,
		"a unit left of a blocked target must approach on the left side (got %.1f, %.1f)" % [
			left_destination.x, left_destination.z
		]
	)

	navigation.queue_free()
	front_unit.queue_free()
	left_unit.queue_free()


func _test_rotated_building_blockers(grid: MapNavigationGrid) -> void:
	var match_root := Node3D.new()
	root.add_child(match_root)
	var building := FakeBuilding.new(["X.", "XS"])
	building.position = Vector3(10.0, 0.0, 10.0)
	building.rotation.y = PI / 2.0
	building.add_to_group("buildings")
	match_root.add_child(building)
	var navigation := NavigationSystemScript.new()
	match_root.add_child(navigation)
	_expect(navigation.setup(grid), "navigation system must initialize with a rotated building")
	_expect(navigation.runtime_map.is_blocked(Vector2i(8, 10)), "rotated solid occupy cells must block their transformed location")
	_expect(
		navigation.runtime_map.is_passable(Vector2i(10, 8), MapNavigationGrid.PASS_VEHICLE)
			and not navigation.runtime_map.is_stoppable(Vector2i(10, 8), MapNavigationGrid.PASS_VEHICLE),
		"the rotated skirt must remain a passable no-stop exit"
	)
	_expect(not navigation.runtime_map.is_blocked(Vector2i(8, 8)), "the stale unrotated blocker location must remain free")
	match_root.queue_free()


## A building footprint: blocked interior at x/y 100..107 with a no-stop apron
## strip in front of it (y 108..111). A unit produced inside gets the
## building's exit point as a mandatory first waypoint and must walk straight
## out through the apron, never through a side or back wall.
func _test_interior_escape(grid: MapNavigationGrid) -> void:
	var interior := {}
	var apron := {}
	for x in range(100, 108):
		for y in range(100, 108):
			interior[Vector2i(x, y)] = true
		for y in range(108, 112):
			apron[Vector2i(x, y)] = true

	var navigation := NavigationSystemScript.new()
	root.add_child(navigation)
	_expect(navigation.setup(grid), "navigation system must initialize")
	navigation.runtime_map.replace_blocked_cells(interior, apron)
	var produced := FakeUnit.new()
	root.add_child(produced)
	produced.global_position = Vector3(103.5, 0.0, 103.5)
	var destination := Vector3(103.5, 0.0, 120.5)
	var exit_point := Vector3(103.5, 0.0, 113.0)
	navigation.command_move([produced], destination, NavConstantsScript.MoveMode.FREE, exit_point)
	_expect(bool(navigation.agent_debug(produced)["route_ready"]), "a unit inside the interior must still get a route immediately")
	var first_open_cell := Vector2i(-1, -1)
	for _iteration in _navigation_tick_count(15.0):
		navigation.call("_navigation_tick")
		var cell: Vector2i = grid.world_to_grid(produced.global_position)
		if first_open_cell.x < 0 and not interior.has(cell) and not apron.has(cell):
			first_open_cell = cell
	_expect(first_open_cell.y >= 112, "the unit must emerge in front of the apron, not through a wall")
	_expect(produced.global_position.distance_to(destination) < 2.0, "a unit produced inside the building must walk out and reach its destination")

	var no_stop_rally_unit := FakeUnit.new()
	root.add_child(no_stop_rally_unit)
	no_stop_rally_unit.global_position = Vector3(103.5, 0.0, 103.5)
	var no_stop_rally := Vector3(103.5, 0.0, 109.5)
	var rally_assignments := navigation.command_move(
		[no_stop_rally_unit],
		no_stop_rally,
		NavConstantsScript.MoveMode.FREE,
		exit_point
	)
	_expect(rally_assignments.size() == 1, "a produced unit must accept a rally point on no-stop space")
	var furthest_front_z := no_stop_rally_unit.global_position.z
	for _iteration in _navigation_tick_count(15.0):
		navigation.call("_navigation_tick")
		furthest_front_z = maxf(furthest_front_z, no_stop_rally_unit.global_position.z)
	_expect(
		furthest_front_z >= exit_point.z - 1.0,
		"a no-stop rally point must not prevent a produced unit from reaching its mandatory building exit"
	)
	_expect(
		no_stop_rally_unit.global_position.distance_to(no_stop_rally) < 2.0,
		"after leaving the building, a produced unit may return to and stop at its no-stop rally point"
	)

	navigation.queue_free()
	produced.queue_free()
	no_stop_rally_unit.queue_free()


func _test_immediate_movement(grid: MapNavigationGrid) -> void:
	var navigation := NavigationSystemScript.new()
	root.add_child(navigation)
	_expect(navigation.setup(grid), "navigation system must initialize")
	_expect(navigation.runtime_map.replace_blocked_cells(_wall_cells()), "walls must apply to the match runtime map")

	var unit := FakeUnit.new()
	root.add_child(unit)
	unit.global_position = Vector3(20.5, 0.0, 128.5)
	navigation.command_move([unit], Vector3(40.5, 0.0, 100.5), NavConstantsScript.MoveMode.FREE)
	_expect(bool(navigation.agent_debug(unit)["route_ready"]), "an obstructed order must have its route ready in the same frame")
	var agent: Dictionary = navigation._agents[unit.get_instance_id()]
	var compact_path: Array = agent["path"]
	_expect(compact_path.size() <= 6,
		"an A* cell route must be simplified to stable corner waypoints (got %d)" % compact_path.size())
	var start_position := unit.global_position
	_advance_navigation(navigation, 0.5)
	_expect(unit.global_position.distance_to(start_position) > 1.0, "the unit must start moving within half a second of the order")

	navigation.queue_free()
	unit.queue_free()


func _test_fast_unit_does_not_overshoot_near_destination(grid: MapNavigationGrid) -> void:
	var navigation := NavigationSystemScript.new()
	root.add_child(navigation)
	_expect(navigation.setup(grid), "navigation system must initialize for near-destination speed limiting")

	var unit := FakeUnit.new(2.0)
	unit.move_speed = 14.0
	root.add_child(unit)
	# A size-two unit has a 0.294 arrival tolerance, but at speed 14 it would
	# otherwise travel 0.56 units per 25 Hz simulation tick. Starting 0.35 away
	# (comfortably inside that one-tick travel distance) reproduces the old
	# exact two-position loop across the destination. _arrival_limited_speed()
	# multiplies distance by TICKS_PER_SECOND and this integrates position by
	# SECONDS_PER_TICK, so the exact landing-in-one-tick behaviour this test
	# checks is invariant to the tick rate; only the travel-per-tick figure
	# above (previously 0.7 at 20 Hz) actually moved.
	unit.global_position = Vector3(99.65, 0.0, 100.0)
	var assignments := navigation.command_move([unit], Vector3(100.0, 0.0, 100.0))
	_expect(assignments.size() == 1, "the nearby destination must receive a movement assignment")
	if not assignments.is_empty():
		var destination: Vector3 = assignments[0]["position"]
		navigation.call("_navigation_tick")
		_expect(unit.global_position.distance_to(destination) <= 0.001,
			"a fast unit's final tick must stop at the destination instead of overshooting it")
		var arrived_position := unit.global_position
		navigation.call("_navigation_tick")
		_expect(unit.global_position.is_equal_approx(arrived_position),
			"a fast unit must remain stopped after its speed-limited final tick")

	navigation.queue_free()
	unit.queue_free()


func _test_selected_unit_navigation_debug(grid: MapNavigationGrid) -> void:
	var navigation := NavigationSystemScript.new()
	root.add_child(navigation)
	_expect(navigation.setup(grid), "navigation system must initialize for selected route debug")
	var unit := FakeUnit.new(3.0)
	root.add_child(unit)
	unit.global_position = Vector3(80.5, 0.0, 80.5)
	unit.set_selected(true)
	navigation.command_move([unit], Vector3(90.5, 0.0, 86.5))
	navigation.call("_navigation_tick")
	var debug = navigation.get_node("NavigationDebug")
	var geometry := debug.get_node("Geometry") as MeshInstance3D
	_expect(
		not navigation.debug_enabled() and not debug.visible and not debug.has_geometry(),
		"navigation diagnostics must start disabled until the unified debug layer is enabled"
	)
	navigation.set_debug_enabled(true)
	navigation.call("_navigation_tick")
	_expect(debug.has_geometry() and geometry.mesh != null \
		and geometry.mesh.get_surface_count() >= 4,
		"enabled diagnostics must draw route, waypoint, look-ahead, and destination surfaces")
	var debug_mesh: Mesh = geometry.mesh
	_advance_navigation(navigation, 1.0)
	_expect(
		geometry.mesh == debug_mesh,
		"route diagnostics must update one reusable mesh instead of allocating a GPU resource every tick"
	)
	navigation.set_debug_enabled(false)
	_expect(not debug.visible and not debug.has_geometry(),
		"disabling navigation diagnostics must hide and clear every route marker")
	navigation.set_debug_enabled(true)
	unit.set_selected(false)
	navigation.call("_navigation_tick")
	_expect(not debug.has_geometry(), "navigation route diagnostics must disappear after deselection")

	navigation.queue_free()
	unit.queue_free()


## Local avoidance uses continuous round geometry even though A* remains a
## discrete cell graph. The diagonal corner of an isolated cell is outside its
## hard circle, while a soft field is already pushing the unit away from it.
func _test_rounded_local_avoidance_field(grid: MapNavigationGrid) -> void:
	var navigation := NavigationSystemScript.new()
	root.add_child(navigation)
	_expect(navigation.setup(grid), "navigation system must initialize for rounded avoidance")
	var blocked_cell := Vector2i(100, 100)
	navigation.runtime_map.replace_blocked_cells({blocked_cell: true})

	var unit := FakeUnit.new(3.0)
	root.add_child(unit)
	var obstacle := grid.grid_to_world(blocked_cell)
	unit.global_position = obstacle + Vector3(1.4, 0.0, 1.4)
	navigation.register_unit(unit)
	var agent: Dictionary = navigation._agents[unit.get_instance_id()]
	var away := (unit.global_position - obstacle).normalized()
	var pressure: Vector3 = navigation.avoidance.terrain_pressure(agent)
	_expect(
		pressure.length() > 0.05 and pressure.normalized().dot(away) > 0.95,
		"an isolated blocked cell must produce a smooth radial pressure field"
	)
	var tangent := Vector3(away.z, 0.0, -away.x) * 0.4
	_expect(
		navigation.avoidance.terrain_sweep_fraction(agent, tangent) >= 0.999,
		"a large round unit must be able to slide past the rounded corner of one cell"
	)
	_expect(
		navigation.avoidance.terrain_sweep_fraction(agent, -away * 1.0) < 0.999,
		"the same rounded cell must retain a hard inner boundary against inward motion"
	)

	navigation.queue_free()
	unit.queue_free()


## A rules-rate-limited harvester must follow one continuous steering arc around
## a wall tip. Repeated target-heading changes make a real Unit stop and turn
## its chassis again, even when the continuous collision geometry is clear.
func _test_large_unit_steers_smoothly_around_corner(grid: MapNavigationGrid) -> void:
	var navigation := NavigationSystemScript.new()
	root.add_child(navigation)
	_expect(navigation.setup(grid), "navigation system must initialize for smooth corner steering")
	var walls := {}
	for x in range(40, 121):
		walls[Vector2i(x, 100)] = true
	navigation.runtime_map.replace_blocked_cells(walls)

	var unit := FakeTurningUnit.new(3.0)
	unit.move_speed = 4.0
	unit.navigation_radius_override = 2.179
	unit.navigation_rotation_radius_override = 3.393
	root.add_child(unit)
	unit.global_position = Vector3(110.5, 0.0, 90.5)
	var target := Vector3(130.5, 0.0, 110.5)
	navigation.command_move([unit], target)
	var agent: Dictionary = navigation._agents[unit.get_instance_id()]
	_expect(float(agent.get("rotation_radius", agent["radius"])) >= 3.39,
		"harvester corner routing must include its full 3.39-unit rotation envelope")
	_expect(int(agent["clearance"]) >= 3,
		"the A* profile must leave enough building clearance for the harvester's long body")
	unit.facing = (navigation.call("_desired_velocity", agent) as Vector3).normalized()
	for _tick in _navigation_tick_count(25.0):
		navigation.call("_navigation_tick")
		if unit.global_position.distance_to(navigation.agent_debug(unit)["destination"]) < 1.0:
			break
	_expect(
		unit.global_position.distance_to(navigation.agent_debug(unit)["destination"]) < 1.0,
		"a large turn-rate-limited unit must still reach the far side of the corner"
	)
	_expect(
		unit.turn_starts <= 1,
		"corner avoidance must be one continuous chassis turn, not repeated steering corrections (got %d)" \
			% unit.turn_starts
	)
	var steering_reversals := 0
	var previous_turn_side := 0
	for index in range(1, unit.commanded_headings.size()):
		var change := unit.commanded_headings[index - 1].signed_angle_to(
			unit.commanded_headings[index], Vector3.UP
		)
		if absf(change) <= 0.01:
			continue
		var turn_side := 1 if change > 0.0 else -1
		if previous_turn_side != 0 and turn_side != previous_turn_side:
			steering_reversals += 1
		previous_turn_side = turn_side
	_expect(steering_reversals <= 2,
		"a harvester must round one building tip without repeated left/right corrections (got %d)" \
			% steering_reversals)

	navigation.queue_free()
	unit.queue_free()


## A harvester skirting a jagged diagonal terrain boundary (staircase cells)
## rides inside the soft pressure band for many seconds. Its commanded course
## must stay one continuous arc: the discrete candidate lattice and the
## position-fed avoidance feedback used to alternate the course left/right at
## half the tick rate, which a rules-turn-rate chassis rendered as constant
## aiming twitches while driving along the obstacle.
func _test_jagged_boundary_steering_stays_smooth(grid: MapNavigationGrid) -> void:
	var navigation := NavigationSystemScript.new()
	root.add_child(navigation)
	_expect(navigation.setup(grid), "navigation system must initialize for jagged boundary steering")
	var walls := {}
	for y in range(80, 132):
		var edge := 96 - int((131 - y) / 2.0)
		for x in range(50, edge + 1):
			walls[Vector2i(x, y)] = true
	navigation.runtime_map.replace_blocked_cells(walls)

	var unit := FakeTurningUnit.new(3.0)
	unit.move_speed = 4.0
	unit.navigation_radius_override = 2.179
	unit.navigation_rotation_radius_override = 3.393
	root.add_child(unit)
	unit.global_position = Vector3(98.5, 0.0, 128.5)
	unit.facing = Vector3(0.0, 0.0, -1.0)
	navigation.command_move([unit], Vector3(64.5, 0.0, 74.5))
	for _tick in _navigation_tick_count(25.0):
		navigation.call("_navigation_tick")
		if unit.global_position.distance_to(navigation.agent_debug(unit)["destination"]) < 1.0:
			break
	_expect(
		unit.global_position.distance_to(navigation.agent_debug(unit)["destination"]) < 1.0,
		"the harvester must clear the jagged boundary and reach its destination"
	)
	var sharp_reversals := 0
	var previous_side := 0
	for index in range(1, unit.commanded_headings.size()):
		var change := unit.commanded_headings[index - 1].signed_angle_to(
			unit.commanded_headings[index], Vector3.UP
		)
		if absf(change) <= 0.035:
			continue
		var side := 1 if change > 0.0 else -1
		if previous_side != 0 and side != previous_side:
			sharp_reversals += 1
		previous_side = side
	_expect(sharp_reversals <= 2,
		"skirting a jagged boundary must be one continuous course, not left/right twitching (got %d sharp reversals)" \
			% sharp_reversals)

	navigation.queue_free()
	unit.queue_free()


func _test_continuous_corner_steering(grid: MapNavigationGrid) -> void:
	var navigation := NavigationSystemScript.new()
	root.add_child(navigation)
	_expect(navigation.setup(grid), "navigation system must initialize for continuous steering")
	var blocked_cell := Vector2i(100, 100)
	navigation.runtime_map.replace_blocked_cells({blocked_cell: true})
	var obstacle := grid.grid_to_world(blocked_cell)
	var unit := FakeTurningUnit.new(3.0)
	unit.move_speed = 4.0
	unit.navigation_radius_override = 2.179
	unit.navigation_rotation_radius_override = 3.393
	root.add_child(unit)
	unit.global_position = obstacle + Vector3(-5.0, 0.0, 0.4)
	unit.facing = Vector3.RIGHT
	navigation.register_unit(unit)
	var agent: Dictionary = navigation._agents[unit.get_instance_id()]
	for _tick in 100:
		var result: Dictionary = navigation.avoidance.resolve_velocity(
			agent, Vector3.RIGHT * unit.move_speed, 0.05, [agent], {}
		)
		var velocity: Vector3 = navigation.avoidance.stabilize_velocity(
			agent, result["velocity"], 0.05, [agent], {}
		)
		unit.navigation_step(velocity, 0.05)
		if unit.global_position.x > obstacle.x + 4.0:
			break
	var large_course_changes := 0
	for index in range(1, unit.commanded_headings.size()):
		if absf(unit.commanded_headings[index - 1].signed_angle_to(
			unit.commanded_headings[index], Vector3.UP
		)) > 0.16:
			large_course_changes += 1
	print("Direct rounded-corner steering: %d large course changes, %d turn starts" % [
		large_course_changes, unit.turn_starts])
	_expect(unit.global_position.x > obstacle.x + 4.0,
		"continuous local steering must carry a large unit past a rounded cell")
	_expect(large_course_changes <= 2 and unit.turn_starts <= 2,
		"rounded-corner steering must stay on one smooth arc (course changes %d, turn starts %d)" % [
			large_course_changes, unit.turn_starts])

	navigation.queue_free()
	unit.queue_free()


## A legitimate long bend can keep the pursuit heading a few degrees ahead of
## the chassis for several seconds. The reachable heading remains inside the
## unit's turn rate on every tick, so elapsed time alone must never convert the
## arc into a periodic stop-and-turn cycle.
func _test_long_steering_arc_does_not_periodically_stop(grid: MapNavigationGrid) -> void:
	var navigation := NavigationSystemScript.new()
	root.add_child(navigation)
	_expect(navigation.setup(grid), "navigation system must initialize for sustained steering arcs")
	navigation.avoidance.turn_rate_stabilization_enabled = true
	var unit := FakeTurningUnit.new(3.0)
	unit.move_speed = 4.0
	unit.facing = Vector3.RIGHT
	root.add_child(unit)
	unit.global_position = Vector3(180.5, 0.0, 180.5)
	navigation.register_unit(unit)
	var agent: Dictionary = navigation._agents[unit.get_instance_id()]
	var delta := 0.05
	var reachable_step := unit.turn_rate * 20.0 * delta * 0.85
	var stationary_ticks := 0
	for tick in 80:
		var desired_direction := Vector3.RIGHT.rotated(
			Vector3.UP, 0.3 + reachable_step * float(tick)
		).normalized()
		var velocity: Vector3 = navigation.avoidance.stabilize_velocity(
			agent, desired_direction * unit.move_speed, delta, [agent], {}
		)
		var previous := unit.global_position
		unit.navigation_step(velocity, delta)
		if unit.global_position.distance_to(previous) <= 0.001:
			stationary_ticks += 1
	_expect(stationary_ticks == 0,
		"a reachable sustained arc must not periodically stop translation (%d stopped ticks)" \
			% stationary_ticks)
	_expect(unit.turn_starts == 0,
		"a reachable sustained arc must not enter turn-in-place (%d entries)" % unit.turn_starts)

	navigation.queue_free()
	unit.queue_free()


## A large bearing is not itself a reason to stop: with a distant pursuit
## target the turn-rate-limited intermediate heading forms a valid driven arc.
## Turn-in-place is reserved for a target inside that arc's capture radius.
func _test_far_target_large_bearing_starts_driven_arc(grid: MapNavigationGrid) -> void:
	var navigation := NavigationSystemScript.new()
	root.add_child(navigation)
	_expect(navigation.setup(grid), "navigation system must initialize for far-bearing arcs")
	navigation.avoidance.turn_rate_stabilization_enabled = true
	var unit := FakeTurningUnit.new(3.0)
	unit.move_speed = 4.0
	unit.facing = Vector3.RIGHT
	root.add_child(unit)
	unit.global_position = Vector3(180.5, 0.0, 180.5)
	navigation.register_unit(unit)
	var agent: Dictionary = navigation._agents[unit.get_instance_id()]
	var target := unit.global_position + Vector3.BACK * 10.0
	agent["steering_target"] = target
	var velocity: Vector3 = navigation.avoidance.stabilize_velocity(
		agent, Vector3.BACK * unit.move_speed, 0.05, [agent], {}
	)
	var previous := unit.global_position
	unit.navigation_step(velocity, 0.05)
	_expect(unit.global_position.distance_to(previous) > 0.1,
		"a distant large-bearing target must begin a driven arc without stopping")
	_expect(unit.turn_starts == 0,
		"a distant large-bearing target must not enter turn-in-place")

	navigation.queue_free()
	unit.queue_free()


## A short-range collision response may stop or sidestep while a new route is
## prepared, but it must never reinterpret a stable route target as a retreat.
## The latter used to alternate with forward motion at rounded grid boundaries
## and made a tracked harvester turn exactly 180 degrees every second.
func _test_local_avoidance_preserves_route_half_plane(grid: MapNavigationGrid) -> void:
	var navigation := NavigationSystemScript.new()
	root.add_child(navigation)
	_expect(navigation.setup(grid),
		"navigation system must initialize for route-direction avoidance")
	var corner := {}
	for offset in range(-3, 4):
		corner[Vector2i(100, 100 + offset)] = true
		corner[Vector2i(100 + offset, 100)] = true
	navigation.runtime_map.replace_blocked_cells(corner)

	var unit := FakeUnit.new(3.0)
	root.add_child(unit)
	navigation.register_unit(unit)
	var agent: Dictionary = navigation._agents[unit.get_instance_id()]
	var reverse_samples := 0
	var worst_progress := 1.0
	for x_offset in range(-4, 5):
		for z_offset in range(-4, 5):
			var sample := Vector3(100.5 + float(x_offset) * 0.55, 0.0,
				100.5 + float(z_offset) * 0.55)
			var cell := grid.world_to_grid(sample)
			if corner.has(cell):
				continue
			unit.global_position = sample
			for heading_index in 24:
				var route_direction := Vector3.RIGHT.rotated(
					Vector3.UP, TAU * float(heading_index) / 24.0
				).normalized()
				var result: Dictionary = navigation.avoidance.resolve_velocity(
					agent, route_direction * unit.move_speed, 0.05, [agent], {}
				)
				var velocity: Vector3 = result["velocity"]
				if velocity.is_zero_approx():
					continue
				var progress := velocity.normalized().dot(route_direction)
				worst_progress = minf(worst_progress, progress)
				if progress < -0.001:
					reverse_samples += 1
	_expect(reverse_samples == 0,
		"local avoidance must not reverse a stable route (samples %d, worst %.3f)" % [
			reverse_samples, worst_progress])

	navigation.queue_free()
	unit.queue_free()


## Course smoothing must not turn a close target into a minimum-radius orbit.
## When the target bearing is too far from the chassis heading, a tracked unit
## needs to turn in place before resuming translation.
func _test_close_target_does_not_become_orbit(grid: MapNavigationGrid) -> void:
	var navigation := NavigationSystemScript.new()
	root.add_child(navigation)
	_expect(navigation.setup(grid), "navigation system must initialize for close-target steering")
	var unit := FakeTurningUnit.new(3.0)
	root.add_child(unit)
	var target := Vector3(100.5, 0.0, 100.5)
	unit.global_position = target + Vector3.RIGHT
	unit.facing = Vector3.FORWARD
	navigation.register_unit(unit)
	var agent: Dictionary = navigation._agents[unit.get_instance_id()]
	var closest := unit.global_position.distance_to(target)
	for _tick in 200:
		var offset := target - unit.global_position
		offset.y = 0.0
		if offset.length() < 0.2:
			break
		var result: Dictionary = navigation.avoidance.resolve_velocity(
			agent, offset.normalized() * unit.move_speed, 0.05, [agent], {}
		)
		var velocity: Vector3 = navigation.avoidance.stabilize_velocity(
			agent, result["velocity"], 0.05, [agent], {}
		)
		unit.navigation_step(velocity, 0.05)
		closest = minf(closest, unit.global_position.distance_to(target))
	_expect(closest < 0.2,
		"a close target outside the current heading must be reached instead of orbited (closest %.2f)" \
			% closest)
	_expect(unit.turn_starts <= 1,
		"escaping a potential orbit should require one turn-in-place phase (got %d)" % unit.turn_starts)

	navigation.queue_free()
	unit.queue_free()


## A radius- and turn-rate-aware follower begins steering before the exact cell
## waypoint. Aiming at cell centres until arrival produces an abrupt near-right
## angle even though both route segments themselves are valid.
func _test_path_lookahead_smooths_waypoint_corner(grid: MapNavigationGrid) -> void:
	var navigation := NavigationSystemScript.new()
	root.add_child(navigation)
	_expect(navigation.setup(grid), "navigation system must initialize for path look-ahead")
	var unit := FakeTurningUnit.new(3.0)
	unit.move_speed = 4.0
	root.add_child(unit)
	var corner_cell := Vector2i(100, 90)
	var corner := grid.grid_to_world(corner_cell)
	unit.global_position = corner + Vector3(-4.0, 0.0, 0.0)
	navigation.register_unit(unit)
	var agent: Dictionary = navigation._agents[unit.get_instance_id()]
	agent["direct_path"] = false
	agent["path"] = [
		corner_cell + Vector2i(-10, 0),
		corner_cell,
		corner_cell + Vector2i(0, 10),
	] as Array[Vector2i]
	agent["path_index"] = 1
	agent["destination"] = grid.grid_to_world(corner_cell + Vector2i(0, 10))
	navigation._agents[unit.get_instance_id()] = agent
	var previous := Vector3.ZERO
	var largest_change := 0.0
	for sample in 19:
		unit.global_position = corner + Vector3(-4.0 + float(sample) * 0.25, 0.0, 0.0)
		var direction: Vector3 = navigation.call("_desired_velocity", agent)
		if not previous.is_zero_approx() and not direction.is_zero_approx():
			largest_change = maxf(largest_change, previous.angle_to(direction))
		previous = direction
	_expect(largest_change < 0.45,
		"a large unit's route heading must blend across a cell corner (largest change %.2f rad)" \
			% largest_change)

	navigation.queue_free()
	unit.queue_free()


## Global A* deliberately keeps square cells, but runtime look-ahead must use
## the same rounded collision geometry as actual motion. This diagonal clears
## the expanded obstacle circle while the conservative square cell/corner test
## rejects it; keeping that square veto pins the yellow target to the waypoint
## until it advances by a visible step.
func _test_path_chord_uses_rounded_geometry(grid: MapNavigationGrid) -> void:
	var navigation := NavigationSystemScript.new()
	root.add_child(navigation)
	_expect(navigation.setup(grid), "navigation system must initialize for rounded path chords")
	var blocked_cell := Vector2i(100, 100)
	navigation.runtime_map.replace_blocked_cells({blocked_cell: true})
	var obstacle := grid.grid_to_world(blocked_cell)
	var unit := FakeUnit.new(3.0)
	root.add_child(unit)
	unit.global_position = obstacle + Vector3(-1.0, 0.0, 4.0)
	navigation.register_unit(unit)
	var agent: Dictionary = navigation._agents[unit.get_instance_id()]
	var rounded_target := obstacle + Vector3(4.0, 0.0, -1.0)
	_expect(navigation.avoidance.terrain_sweep_fraction(
		agent, rounded_target - unit.global_position
	) >= 0.999, "the diagonal fixture must clear the rounded obstacle field")
	_expect(not navigation.call("_has_clear_line", unit.global_position, rounded_target, agent),
		"the same diagonal must expose the old square corner veto")
	_expect(navigation.call("_path_chord_is_clear", agent, unit.global_position, rounded_target),
		"runtime path look-ahead must accept a chord that its rounded body can traverse")
	var blocked_target := obstacle + Vector3(1.0, 0.0, -4.0)
	_expect(not navigation.call(
		"_path_chord_is_clear", agent, unit.global_position, blocked_target
	), "rounded path chords must still reject a real cut through the obstacle")
	unit.global_position = obstacle
	var escape_target := obstacle + Vector3(4.0, 0.0, 0.0)
	_expect(not navigation.call(
		"_path_chord_is_clear", agent, unit.global_position, escape_target
	), "the inside-obstacle escape exception must not clear a long chord through its building")

	# This test is immediately followed by another NavigationSystem fixture.
	# Free synchronously so its node_added hook cannot register the next test's
	# units before the queued deletion is flushed by SceneTree.
	navigation.free()
	unit.free()


## A collision can push a large body across the outgoing side of a waypoint
## without bringing its centre close to the waypoint cell centre. Route
## progress must advance through that cross-section instead of steering back.
func _test_missed_waypoint_advances_through_route_gate(grid: MapNavigationGrid) -> void:
	var navigation := NavigationSystemScript.new()
	root.add_child(navigation)
	_expect(navigation.setup(grid), "navigation system must initialize for waypoint gates")
	var unit := FakeUnit.new(3.0)
	root.add_child(unit)
	var corner_cell := Vector2i(100, 90)
	var corner := grid.grid_to_world(corner_cell)
	unit.global_position = corner + Vector3(0.9, 0.0, 1.0)
	navigation.register_unit(unit)
	var agent: Dictionary = navigation._agents[unit.get_instance_id()]
	agent["direct_path"] = false
	agent["path"] = [
		corner_cell + Vector2i(-10, 0),
		corner_cell,
		corner_cell + Vector2i(0, 10),
	] as Array[Vector2i]
	agent["path_index"] = 1
	agent["destination"] = grid.grid_to_world(corner_cell + Vector2i(0, 10))
	var desired: Vector3 = navigation.call("_desired_velocity", agent)
	_expect(int(agent["path_index"]) == 2,
		"a unit already across the outgoing waypoint gate must advance monotonically")
	_expect(desired.normalized().dot(Vector3.BACK) > 0.9,
		"a missed waypoint must keep steering along the outgoing route, not back to its centre")
	var world_path: Array[Vector3] = [
		grid.grid_to_world(corner_cell + Vector2i(-10, 0)),
		corner,
		grid.grid_to_world(corner_cell + Vector2i(0, 10)),
	]
	agent["route_lane_offset"] = 6.0
	agent["route_lane_min"] = -6.0
	agent["route_lane_max"] = 6.0
	agent["_lane_rebase_index"] = 1
	agent["_lane_rebase_side"] = 0
	var outer_lane_position := corner + Vector3(6.0, 0.0, 1.0)
	_expect(
		int(navigation.call(
			"_advanced_path_index", agent, world_path, 1, outer_lane_position, unit.move_speed
		)) == 2,
		"an outer group lane must cross the waypoint gate without curving back to its centre"
	)

	navigation.queue_free()
	unit.queue_free()


func _test_slots_and_collision(grid: MapNavigationGrid) -> void:
	var navigation := NavigationSystemScript.new()
	root.add_child(navigation)
	_expect(navigation.setup(grid), "navigation system must initialize")
	var units: Array[FakeUnit] = []
	for index in 8:
		var unit := FakeUnit.new()
		root.add_child(unit)
		unit.global_position = Vector3(10.0 + float(index), 0.0, 10.0)
		units.append(unit)
	var assignments := navigation.command_move(units, Vector3(30.5, 0.0, 30.5), NavConstantsScript.MoveMode.FREE)
	_expect(assignments.size() == units.size(), "a group command must synchronously assign every destination")
	_expect(navigation.command_log().size() == 1, "movement commands must be recorded for bug-report replay")
	for unit in units:
		_expect(bool(navigation.agent_debug(unit)["route_ready"]), "every unit in a group must have a route immediately")
	_advance_navigation(navigation, 12.0)
	var claimed: Array[Dictionary] = []
	for unit in units:
		var destination: Vector3 = navigation.agent_debug(unit)["destination"]
		var debug_agent: Dictionary = navigation._agents[unit.get_instance_id()]
		_expect(unit.global_position.distance_to(destination) < 0.6,
			"every free-move unit must settle on its claimed block (id %d pos %.2f,%.2f dest %.2f,%.2f dist %.2f direct %s path %s index %d blocked %.2f steer %.2f,%.2f)" % [
				int(debug_agent["id"]),
				unit.global_position.x, unit.global_position.z, destination.x, destination.z,
				unit.global_position.distance_to(destination), str(debug_agent["direct_path"]),
				str(debug_agent["path"]), int(debug_agent["path_index"]), float(debug_agent["blocked_time"]),
				(debug_agent["steering_target"] as Vector3).x, (debug_agent["steering_target"] as Vector3).z])
		claimed.append({"anchor": navigation._parking_anchor(destination, 1), "span": 1})
	for a in claimed.size():
		for b in range(a + 1, claimed.size()):
			_expect(
				not navigation._blocks_conflict(claimed[a]["anchor"], 1, claimed[b]["anchor"], 1),
				"claimed parking blocks must keep a one-cell gap (%s vs %s)" % [
					str(claimed[a]["anchor"]), str(claimed[b]["anchor"])]
			)
	units[0].move_speed = 9.0
	units[1].move_speed = 3.0
	navigation.command_move([units[0], units[1]], Vector3(90.0, 0.0, 90.0), NavConstantsScript.MoveMode.FORMATION)
	_expect(is_equal_approx(float(navigation.agent_debug(units[0])["group_speed"]), 3.0), "formation speed must match its slowest member")

	var left := FakeUnit.new()
	var right := FakeUnit.new()
	root.add_child(left)
	root.add_child(right)
	left.global_position = Vector3(100.0, 0.0, 100.0)
	right.global_position = Vector3(102.0, 0.0, 100.0)
	navigation.command_move([left], Vector3(110.0, 0.0, 100.0))
	navigation.command_move([right], Vector3(90.0, 0.0, 100.0))
	var closest_approach := INF
	var largest_detour := 0.0
	for _iteration in _navigation_tick_count(4.0):
		navigation.call("_navigation_tick")
		closest_approach = minf(closest_approach, left.global_position.distance_to(right.global_position))
		largest_detour = maxf(largest_detour, maxf(
			absf(left.global_position.z - 100.0),
			absf(right.global_position.z - 100.0)
		))
	# In the open, counter-movers steer around each other; either way a head-on
	# pair must swap sides cleanly and on time.
	_expect(left.global_position.distance_to(Vector3(110.0, 0.0, 100.0)) < 1.0, "a head-on mover must pass a friendly counter-mover and arrive")
	_expect(right.global_position.distance_to(Vector3(90.0, 0.0, 100.0)) < 1.0, "the opposing mover must arrive as well")
	var open_contact := float(navigation._agents[left.get_instance_id()]["radius"]) \
		+ float(navigation._agents[right.get_instance_id()]["radius"])
	_expect(closest_approach >= open_contact - 0.02,
		"counter-movers in open space must steer instead of squeezing (closest %.2f, contact %.2f)" % [closest_approach, open_contact])
	_expect(largest_detour > open_contact * 0.4,
		"an open-space pass must contain a visible lateral detour (only %.2f)" % largest_detour)

	navigation.queue_free()
	for unit in units:
		unit.queue_free()
	left.queue_free()
	right.queue_free()


## A destination is accepted on the unit's real body geometry, not on the
## routing grid's whole-cell clearance window. The window expanded every
## footprint cell by the rotation envelope, which kept a player's move order a
## further sqrt(2) off any diagonal or stair-stepped edge and, for a long
## chassis, further still off a straight one.
func _test_destination_uses_body_geometry(grid: MapNavigationGrid) -> void:
	var navigation := NavigationSystemScript.new()
	root.add_child(navigation)
	_expect(navigation.setup(grid), "navigation system must initialize for destination geometry")

	# A straight wall whose face lies on world x = 100. The block centre for a
	# span-2 footprint clicked here sits at x = 101, one unit clear of it.
	var straight := {}
	for y in MapNavigationGrid.NAV_SIZE:
		for x in range(0, 100):
			straight[Vector2i(x, y)] = true
	navigation.runtime_map.replace_blocked_cells(straight)
	var target := Vector3(101.0, 0.0, 101.0)

	# Long chassis, narrow body: the rotation envelope is what used to decide
	# this, though a parked unit never turns on it.
	var slim := FakeUnit.new(2.0)
	slim.navigation_radius_override = 0.5
	slim.navigation_rotation_radius_override = 1.9
	root.add_child(slim)
	slim.global_position = Vector3(120.5, 0.0, 120.5)
	navigation.register_unit(slim)
	_expect(navigation.can_move_to([slim], target),
		"a narrow body one unit clear of a straight wall must be a legal destination")

	# Same spot, same envelope, body too wide to actually stand there.
	var wide := FakeUnit.new(2.0)
	wide.navigation_radius_override = 1.4
	wide.navigation_rotation_radius_override = 1.9
	root.add_child(wide)
	wide.global_position = Vector3(120.5, 0.0, 120.5)
	navigation.register_unit(wide)
	_expect(not navigation.can_move_to([wide], target),
		"a body wider than the gap must still be refused, or the check is a no-op")

	# A 45-degree staircase: the old square window caught the cell diagonally
	# behind the edge and refused a spot the body clears.
	var staircase := {}
	for y in MapNavigationGrid.NAV_SIZE:
		for x in MapNavigationGrid.NAV_SIZE:
			if x + y <= 199:
				staircase[Vector2i(x, y)] = true
	navigation.runtime_map.replace_blocked_cells(staircase)
	var diagonal := FakeUnit.new(2.0)
	diagonal.navigation_radius_override = 0.9
	diagonal.navigation_rotation_radius_override = 1.9
	root.add_child(diagonal)
	diagonal.global_position = Vector3(120.5, 0.0, 120.5)
	navigation.register_unit(diagonal)
	_expect(navigation.can_move_to([diagonal], target),
		"a body that clears a stair-stepped edge must be a legal destination there")

	navigation.runtime_map.replace_blocked_cells({})
	navigation.queue_free()
	slim.queue_free()
	wide.queue_free()
	diagonal.queue_free()


## Regression for approach_anchor(): a rally cell rejected by a hair of body
## overlap next to an otherwise-open edge must fall back to the nearest legal
## cell, not to whatever the approach line happens to hit first.
##
## Geometry: a single-row wall at z=50 spans x 90..150. The rally cell (100,49)
## sits right under it -- its body disc (radius 0.55) pokes 0.05m into the
## wall, just enough for the exact body-geometry check to refuse it, while
## whole-cell clearance (0 cells at this radius) would have allowed it. A
## valid cell sits one ring away at (99,48), clear of the wall by 0.7m. The
## ordering unit stands due west at (50,49), on the same row as the rally
## cell, so a plain walk back toward it stays under the wall's overlap for 11
## cells (x 99..90 are all still inside the wall's span) before reaching open
## ground at x=89 -- about 11m off target, versus ~1.4m for the ring cell.
func _test_approach_anchor_prefers_nearest_valid_block(grid: MapNavigationGrid) -> void:
	var navigation := NavigationSystemScript.new()
	root.add_child(navigation)
	_expect(navigation.setup(grid), "navigation system must initialize for approach-anchor competition")

	var wall := {}
	for x in range(90, 151):
		wall[Vector2i(x, 50)] = true
	navigation.runtime_map.replace_blocked_cells(wall)

	var unit := FakeUnit.new()
	unit.navigation_radius_override = 0.55
	unit.navigation_rotation_radius_override = 0.55
	root.add_child(unit)
	unit.global_position = Vector3(50.5, 0.0, 49.5)

	var target := Vector3(100.5, 0.0, 49.5)
	var assignment := navigation.command_move([unit], target)[0] as Dictionary
	var chosen: Vector3 = assignment["position"]
	_expect(
		chosen.distance_to(target) < 2.5,
		"a hair of body overlap near an edge must not redirect the order metres off target (got %.2f, %.2f)" % [
			chosen.x, chosen.z
		]
	)
	_expect(
		chosen.distance_to(Vector3(89.5, 0.0, 49.5)) > 2.0,
		"the far line-walk cell along the same wall band must lose to the nearer ring cell"
	)

	navigation.runtime_map.replace_blocked_cells({})
	navigation.queue_free()
	unit.queue_free()


## A stationary friend sitting exactly on the route must be flowed around, not
## treated as a dead end: contact quantizing every candidate to zero used to
## freeze both units at their first touch.
func _test_slide_around_stopped_friend(grid: MapNavigationGrid) -> void:
	var navigation := NavigationSystemScript.new()
	root.add_child(navigation)
	_expect(navigation.setup(grid), "navigation system must initialize")

	var blocker := FakeUnit.new()
	var runner := FakeUnit.new()
	root.add_child(blocker)
	root.add_child(runner)
	blocker.global_position = Vector3(105.0, 0.0, 100.0)
	runner.global_position = Vector3(100.0, 0.0, 100.0)
	navigation.register_unit(blocker)
	var destination := Vector3(110.0, 0.0, 100.0)
	navigation.command_move([runner], destination)
	_advance_navigation(navigation, 5.0)
	_expect(runner.global_position.distance_to(destination) < 1.0, "a unit must slide around a stopped friend on its route")

	navigation.queue_free()
	blocker.queue_free()
	runner.queue_free()


## Regression for the reported jitter: a non-omnidirectional unit ordered to a
## point behind an adjacent friendly used to ram/stop/turn-a-few-degrees in a
## loop at the 20 Hz nav tick (turn-rate stabilization disabled, blocked-time
## measured off solver output instead of displacement, and the squeeze
## fallback's terrain-only passability check ramming the friendly at full
## speed). It must instead arc around on a bounded number of driven turns.
func _test_turning_unit_arcs_around_stopped_friend(grid: MapNavigationGrid) -> void:
	var navigation := NavigationSystemScript.new()
	root.add_child(navigation)
	_expect(navigation.setup(grid), "navigation system must initialize")

	var blocker := FakeUnit.new(3.0)
	var runner := FakeTurningUnit.new(3.0)
	runner.turn_rate = 0.175
	runner.move_speed = 4.0
	runner.facing = Vector3.RIGHT
	root.add_child(blocker)
	root.add_child(runner)
	blocker.global_position = Vector3(105.5, 0.0, 100.5)
	# Near contact: combined radius for two size-3 agents is ~2.52; starting
	# the runner 2.5 units short of the blocker puts it right at the edge of
	# contact, exactly the adjacency the field report started from.
	runner.global_position = Vector3(103.0, 0.0, 100.5)
	navigation.register_unit(blocker)
	var destination := Vector3(114.5, 0.0, 100.5)
	navigation.command_move([runner], destination)
	_advance_navigation(navigation, 10.0)
	_expect(runner.global_position.distance_to(destination) < 1.5,
		"a turning unit must reach a destination behind an adjacent friend instead of jittering forever")
	_expect(runner.turn_starts <= 3,
		"arcing around an adjacent friend must stay on a handful of driven turns, not repeatedly stop-turn-step (%d turn starts)" \
			% runner.turn_starts)

	navigation.queue_free()
	blocker.queue_free()
	runner.queue_free()


## White-box: a turn-in-place tick reports non-zero solver velocity but near-
## zero actual displacement. `blocked_time` must still accrue from that (via
## the previous tick's `_achieved_velocity`), so the friendly-yield path
## fires and a friendly sitting on the route steps aside.
func _test_turn_in_place_counts_as_blocked_and_triggers_yield(grid: MapNavigationGrid) -> void:
	var navigation := NavigationSystemScript.new()
	root.add_child(navigation)
	_expect(navigation.setup(grid), "navigation system must initialize")

	var blocker := FakeUnit.new(3.0)
	var runner := FakeTurningUnit.new(3.0)
	runner.turn_rate = 0.175
	runner.move_speed = 4.0
	# Facing squarely away from the route forces sustained turn-in-place
	# (bearing far beyond the driven-arc capture window) instead of a
	# gradually steered arc, so displacement stays ~zero tick after tick.
	runner.facing = Vector3.LEFT
	root.add_child(blocker)
	root.add_child(runner)
	blocker.global_position = Vector3(102.5, 0.0, 100.5)
	runner.global_position = Vector3(100.5, 0.0, 100.5)
	navigation.register_unit(blocker)
	navigation.command_move([runner], Vector3(114.5, 0.0, 100.5))
	# Five ticks (one bare call plus a four-tick loop, unmerged in the
	# original): a short settle window for blocked_time to accrue, not a
	# specific-tick-counted mechanism, so it converts as a duration.
	_advance_navigation(navigation, 5.0 * MatchClockScript.SECONDS_PER_TICK)
	var runner_agent: Dictionary = navigation._agents[runner.get_instance_id()]
	_expect(float(runner_agent["blocked_time"]) > 0.0,
		"a turn-in-place tick must accrue blocked_time from displacement, not just solver velocity")

	var blocker_start := blocker.global_position
	var yield_ticks := ceili(
		(NavConstantsScript.FRIENDLY_YIELD_TRIGGER_SECONDS + NavConstantsScript.FRIENDLY_YIELD_SECONDS)
		/ MatchClockScript.SECONDS_PER_TICK
	) + 5
	for _iteration in yield_ticks:
		navigation.call("_navigation_tick")
	_expect(blocker.global_position.distance_to(blocker_start) > 0.2,
		"a friendly on a stalled turning unit's route must be asked to yield")

	navigation.queue_free()
	blocker.queue_free()
	runner.queue_free()


## White-box: once `blocked_time` is nonzero, the squeeze fallback's direct
## full-speed branch must not ignore a friendly at contact on the route — it
## used to (a terrain-only passability check), ramming straight through it.
func _test_squeeze_does_not_ram_adjacent_friend(grid: MapNavigationGrid) -> void:
	var navigation := NavigationSystemScript.new()
	root.add_child(navigation)
	_expect(navigation.setup(grid), "navigation system must initialize")

	var blocker := FakeUnit.new(3.0)
	var runner := FakeUnit.new(3.0)
	root.add_child(blocker)
	root.add_child(runner)
	blocker.global_position = Vector3(102.6, 0.0, 100.5)
	runner.global_position = Vector3(100.5, 0.0, 100.5)
	navigation.register_unit(blocker)
	navigation.register_unit(runner)
	var runner_agent: Dictionary = navigation._agents[runner.get_instance_id()]
	# Force the squeeze gate open exactly as a real stall would over time.
	runner_agent["blocked_time"] = NavConstantsScript.FRIENDLY_YIELD_TRIGGER_SECONDS
	navigation._agents[runner.get_instance_id()] = runner_agent
	var blocker_agent: Dictionary = navigation._agents[blocker.get_instance_id()]
	# A real navigation tick's phase 1 stamps `_v_pref` on every agent
	# (idle ones included, as ZERO) before phase 2 ever runs; this direct
	# white-box call bypasses that, so set it explicitly to mark the blocker
	# idle — the squeeze branch only restricts speed against a stationary
	# neighbour, by design, so a reciprocal moving-crowd squeeze keeps its
	# full-speed pass-through.
	blocker_agent["_v_pref"] = Vector3.ZERO
	navigation._agents[blocker.get_instance_id()] = blocker_agent

	var direction_to_blocker := runner.global_position.direction_to(blocker.global_position)
	var nearby: Array = [runner_agent, blocker_agent]
	var result: Dictionary = navigation.avoidance.resolve_velocity(
		runner_agent, direction_to_blocker * runner.move_speed, 0.05, nearby, {}
	)
	var resolved: Vector3 = result["velocity"]
	var toward_blocker := resolved.dot(direction_to_blocker)
	_expect(toward_blocker < runner.move_speed * 0.5,
		"a stalled squeeze must not resolve to near-full speed straight into an adjacent friend (got %.2f of %.2f)" \
			% [toward_blocker, runner.move_speed])

	navigation.queue_free()
	blocker.queue_free()
	runner.queue_free()


## The reported field failure: a group ordered to one point jams at its first
## internal contact. Every unit must keep flowing and settle on its own slot.
func _test_group_convergence(grid: MapNavigationGrid) -> void:
	var navigation := NavigationSystemScript.new()
	root.add_child(navigation)
	_expect(navigation.setup(grid), "navigation system must initialize")
	var units: Array[FakeUnit] = []
	for index in 6:
		var unit := FakeUnit.new()
		root.add_child(unit)
		unit.global_position = Vector3(40.0 + float(index % 3), 0.0, 40.0 + float(index / 3))
		units.append(unit)
	var assignments := navigation.command_move(units, Vector3(60.0, 0.0, 60.0), NavConstantsScript.MoveMode.FREE)
	_advance_navigation(navigation, 20.0)
	for assignment in assignments:
		var unit: Node3D = assignment["unit"]
		var slot: Vector3 = assignment["position"]
		_expect(unit.global_position.distance_to(slot) < 3.5, "every unit of a converging group must reach its slot instead of jamming on contact")

	navigation.queue_free()
	for unit in units:
		unit.queue_free()


## A packed square moved ten cells sideways — the everyday group move. The
## pack must slide over as a shape: no scrum, and no squeezing through the
## target point (the mid-flight spread must stay near the resting spread).
func _test_group_shift_keeps_shape(grid: MapNavigationGrid) -> void:
	var navigation := NavigationSystemScript.new()
	root.add_child(navigation)
	_expect(navigation.setup(grid), "navigation system must initialize")

	var units: Array[FakeUnit] = []
	for index in 25:
		var unit := FakeUnit.new()
		root.add_child(unit)
		unit.global_position = Vector3(100.5 + float(index % 5), 0.0, 100.5 + float(index / 5))
		units.append(unit)
	navigation.command_move(units, Vector3(112.5, 0.0, 102.5), NavConstantsScript.MoveMode.FREE)

	var tick_seconds := MatchClockScript.SECONDS_PER_TICK
	# 60 s budget, 5 s idle-settle window: durations, converted to ticks at
	# the simulation rate rather than hardcoded against the old 20 Hz.
	var max_ticks := _navigation_tick_count(60.0)
	var idle_ticks_to_finish := _navigation_tick_count(5.0)
	var previous: Array[Vector3] = []
	for unit in units:
		previous.append(unit.global_position)
	var last_active_tick := 0
	var elapsed_ticks := max_ticks
	var minimum_spread := INF
	for tick in range(1, max_ticks + 1):
		navigation.call("_navigation_tick")
		var moved := false
		var centroid := Vector3.ZERO
		for index in units.size():
			if units[index].global_position.distance_to(previous[index]) > 0.005:
				moved = true
			previous[index] = units[index].global_position
			centroid += units[index].global_position
		centroid /= float(units.size())
		var spread := 0.0
		for unit in units:
			spread = maxf(spread, unit.global_position.distance_to(centroid))
		minimum_spread = minf(minimum_spread, spread)
		if moved:
			last_active_tick = tick
		elif tick - last_active_tick >= idle_ticks_to_finish:
			elapsed_ticks = tick
			break
	print("Group shift: settled in %.1f s, min mid-flight spread %.1f (gapped resting ~5.7)" % [
		float(last_active_tick) * tick_seconds, minimum_spread])
	_expect(elapsed_ticks < max_ticks, "a shifted pack must settle, not churn forever")
	_expect(float(last_active_tick) * tick_seconds < 8.0, "a ten-cell group shift must settle within 8 seconds")
	_expect(minimum_spread > 1.8, "the pack must translate as a shape, not squeeze through the target point")

	navigation.queue_free()
	for unit in units:
		unit.queue_free()


## An idle unit displaced off a choke point parks nearby on the grid and stays
## (returning would displace the passer forever). A commanded unit owns a
## unique reserved block, so it walks back once the passer is through.
func _test_yield_behaviour(grid: MapNavigationGrid) -> void:
	var navigation := NavigationSystemScript.new()
	root.add_child(navigation)
	_expect(navigation.setup(grid), "navigation system must initialize")

	var idle := FakeUnit.new()
	root.add_child(idle)
	idle.global_position = Vector3(120.5, 0.0, 120.5)
	navigation.register_unit(idle)
	navigation.call("_request_yield", idle, Vector3.RIGHT)
	_advance_navigation(navigation, 1.0)
	var displaced_position := idle.global_position
	_expect(displaced_position.x > 121.5, "a yielded idle unit must move aside")
	var parked: Vector3 = navigation.agent_debug(idle)["destination"]
	_expect(
		absf(fposmod(parked.x, 1.0) - 0.5) < 0.001 and absf(fposmod(parked.z, 1.0) - 0.5) < 0.001,
		"a yielded idle unit must park on a grid cell center (got %.2f, %.2f)" % [parked.x, parked.z]
	)
	_advance_navigation(navigation, 2.0)
	_expect(idle.global_position.distance_to(displaced_position) < 0.01, "a yielded idle unit must not return to the choke point")

	var owner := FakeUnit.new()
	root.add_child(owner)
	owner.global_position = Vector3(140.5, 0.0, 120.5)
	var home := owner.global_position
	navigation.command_move([owner], home)
	navigation.call("_navigation_tick")
	var prepared_order_count := owner.prepared_navigation_targets.size()
	navigation.call("_request_yield", owner, Vector3.RIGHT)
	_expect(owner.prepared_navigation_targets.size() == prepared_order_count, "an internal yield must not enter the player-order preparation API")
	_advance_navigation(navigation, 0.4)
	_expect(owner.global_position.x > 141.5, "a yielded commanded unit must move aside first")
	_advance_navigation(navigation, 3.0)
	_expect(owner.global_position.distance_to(home) < 0.3, "a commanded unit must return to its reserved block after yielding")
	_expect(owner.prepared_navigation_targets.size() == prepared_order_count, "resuming after yield must preserve the original order instead of issuing a replacement")

	navigation.queue_free()
	idle.queue_free()
	owner.queue_free()


## A packed group routed around a sharp wall tip: every unit's A* path runs
## through the same corridor, so raw cell-by-cell waypoints land inside the
## moving crowd. Pre-simplifying those paths to stable corner waypoints must
## keep the whole group flowing without runtime line-of-sight skipping.
func _test_group_rounds_sharp_corner(grid: MapNavigationGrid) -> void:
	var navigation := NavigationSystemScript.new()
	root.add_child(navigation)
	_expect(navigation.setup(grid), "navigation system must initialize")
	var walls := {}
	for x in range(40, 121):
		walls[Vector2i(x, 100)] = true
	navigation.runtime_map.replace_blocked_cells(walls)

	var units: Array[FakeUnit] = []
	for index in 20:
		var unit := FakeUnit.new()
		root.add_child(unit)
		unit.global_position = Vector3(60.0 + float(index % 5), 0.0, 90.0 + float(index / 5))
		units.append(unit)
	var assignments := navigation.command_move(units, Vector3(60.5, 0.0, 140.5), NavConstantsScript.MoveMode.FREE)
	var maximum_tick_usec := 0
	var maximum_tick_index := 0
	for _iteration in _navigation_tick_count(60.0):
		var tick_start := Time.get_ticks_usec()
		navigation.call("_navigation_tick")
		var tick_usec := Time.get_ticks_usec() - tick_start
		if tick_usec > maximum_tick_usec:
			maximum_tick_usec = tick_usec
			maximum_tick_index = _iteration
	print("Sharp-corner crowd: max tick %.2f ms at %d" % [
		float(maximum_tick_usec) / 1000.0, maximum_tick_index
	])
	for assignment in assignments:
		var unit: Node3D = assignment["unit"]
		var slot: Vector3 = assignment["position"]
		# One-way yields may nudge an arrived unit a few cells off its exact
		# slot; the guarded failure mode leaves units ~40+ cells behind.
		_expect(unit.global_position.distance_to(slot) < 10.0,
			"no unit of a group rounding a sharp corner may be left behind in a jam (dist %.1f, pos %.1f,%.1f slot %.1f,%.1f)" % [
				unit.global_position.distance_to(slot), unit.global_position.x, unit.global_position.z, slot.x, slot.z])

	navigation.queue_free()
	for unit in units:
		unit.queue_free()


## Reproduction order matters: a group already travelling in spaced lanes is
## cheap to reverse. First converge it onto one shared corner, then reverse
## the whole compressed queue by 180 degrees while avoidance contacts are
## active.
func _test_bunched_group_reverses_at_corner(grid: MapNavigationGrid) -> void:
	var navigation := NavigationSystemScript.new()
	root.add_child(navigation)
	_expect(navigation.setup(grid), "navigation must initialize for the bunched reversal regression")
	var walls := {}
	for x in range(40, 121):
		walls[Vector2i(x, 100)] = true
	navigation.runtime_map.replace_blocked_cells(walls)

	var units: Array[FakeUnit] = []
	for index in 20:
		var unit := FakeUnit.new()
		root.add_child(unit)
		unit.global_position = Vector3(60.0 + float(index % 5), 0.0, 90.0 + float(index / 5))
		units.append(unit)
	navigation.command_move(
		units, Vector3(60.5, 0.0, 140.5), NavConstantsScript.MoveMode.FREE
	)
	# The original sharp-corner benchmark reaches maximum contact around 2.75 s
	# in (55 ticks at the old 20 Hz navigation tick). Stop just after the queue
	# has compressed at the shared waypoint.
	_advance_navigation(navigation, 2.75)

	navigation.command_move(
		units, Vector3(60.5, 0.0, 80.5), NavConstantsScript.MoveMode.FREE
	)
	var maximum_tick_usec := 0
	var maximum_tick_index := 0
	for tick in _navigation_tick_count(15.0):
		var tick_start := Time.get_ticks_usec()
		navigation.call("_navigation_tick")
		var tick_usec := Time.get_ticks_usec() - tick_start
		if tick_usec > maximum_tick_usec:
			maximum_tick_usec = tick_usec
			maximum_tick_index = tick
	print("Bunched 180-degree reversal: max tick %.2f ms at %d" % [
		float(maximum_tick_usec) / 1000.0, maximum_tick_index
	])

	navigation.queue_free()
	for unit in units:
		unit.queue_free()


## A long final leg around a large solid region used to gather every obstacle
## in a distance-squared square for every unit and every visibility probe.
## The spike began only when the crowd advanced onto that common final leg.
func _test_dense_group_rounds_solid_region(grid: MapNavigationGrid) -> void:
	var navigation := NavigationSystemScript.new()
	root.add_child(navigation)
	_expect(navigation.setup(grid), "navigation must initialize for the solid-region performance regression")
	var blocked := {}
	for y in range(80, 151):
		for x in range(60, 141):
			blocked[Vector2i(x, y)] = true
	navigation.runtime_map.replace_blocked_cells(blocked)

	var units: Array[FakeUnit] = []
	for index in 16:
		var unit := FakeUnit.new()
		root.add_child(unit)
		unit.global_position = Vector3(88.5 + float(index % 4), 0.0, 72.5 + float(index / 4))
		units.append(unit)
	var command_start := Time.get_ticks_usec()
	navigation.command_move(
		units, Vector3(90.5, 0.0, 165.5), NavConstantsScript.MoveMode.FREE
	)
	var command_usec := Time.get_ticks_usec() - command_start

	var maximum_tick_usec := 0
	var maximum_tick_index := 0
	for tick in _navigation_tick_count(30.0):
		var tick_start := Time.get_ticks_usec()
		navigation.call("_navigation_tick")
		var tick_usec := Time.get_ticks_usec() - tick_start
		if tick_usec > maximum_tick_usec:
			maximum_tick_usec = tick_usec
			maximum_tick_index = tick
	print("Solid-region crowd: max tick %.2f ms at %d" % [
		float(maximum_tick_usec) / 1000.0, maximum_tick_index
	])
	print("Solid-region crowd: command %.2f ms" % (float(command_usec) / 1000.0))
	_expect(
		maximum_tick_usec < 100_000,
		"a dense group entering a long final leg must not create a 3-FPS navigation tick (%.2f ms)" \
			% (float(maximum_tick_usec) / 1000.0)
	)

	navigation.queue_free()
	for unit in units:
		unit.queue_free()


## Two harvester-sized bodies approach the same A* corner abreast. Their
## centre paths are allowed to share the compact cell waypoint, but the runtime
## targets must remain ordered across the route so neither body is funnelled
## into the wall by the other one.
func _test_large_pair_keeps_lanes_at_shared_corner(grid: MapNavigationGrid) -> void:
	var navigation := NavigationSystemScript.new()
	root.add_child(navigation)
	_expect(navigation.setup(grid), "navigation system must initialize for shared-corner lanes")
	var walls := {}
	for x in range(40, 121):
		walls[Vector2i(x, 100)] = true
	navigation.runtime_map.replace_blocked_cells(walls)

	var inner := FakeUnit.new(3.0)
	var outer := FakeUnit.new(3.0)
	root.add_child(inner)
	root.add_child(outer)
	inner.global_position = Vector3(108.5, 0.0, 90.1)
	outer.global_position = Vector3(108.5, 0.0, 87.5)
	var units: Array[Node3D] = [inner, outer]
	var assignments := navigation.command_move(
		units, Vector3(132.5, 0.0, 112.5), NavConstantsScript.MoveMode.FREE
	)
	var inner_agent: Dictionary = navigation._agents[inner.get_instance_id()]
	var outer_agent: Dictionary = navigation._agents[outer.get_instance_id()]
	_expect(not (inner_agent["path"] as Array).is_empty() \
		and not (outer_agent["path"] as Array).is_empty(),
		"both large units must receive an indirect route around the wall tip")
	var contact_distance := float(inner_agent["radius"]) + float(outer_agent["radius"])
	var comfort_distance := contact_distance + minf(
		float(inner_agent["radius"]), float(outer_agent["radius"])
	) * 0.35
	_expect(float(inner_agent["route_lane_max"]) - float(inner_agent["route_lane_min"]) \
		>= comfort_distance,
		"parallel route lanes must clear both bodies and their soft avoidance field")

	var settled_tick := _navigation_tick_count(35.0)
	var contact_streak := 0
	var longest_contact_streak := 0
	for tick in range(1, settled_tick + 1):
		navigation.call("_navigation_tick")
		if inner.global_position.distance_to(outer.global_position) < contact_distance + 0.05:
			contact_streak += 1
			longest_contact_streak = maxi(longest_contact_streak, contact_streak)
		else:
			contact_streak = 0
		if assignments.all(func(assignment: Dictionary) -> bool:
			return (assignment["unit"] as Node3D).global_position.distance_to(
				navigation.agent_debug(assignment["unit"])["destination"]
			) < 1.0
		):
			settled_tick = tick
			break
	_expect(settled_tick < _navigation_tick_count(30.0),
		"both large units must clear one shared wall corner without leaving a unit nose-first at terrain (%.1f s)" \
			% (float(settled_tick) * MatchClockScript.SECONDS_PER_TICK))
	_expect(longest_contact_streak < _navigation_tick_count(0.5),
		"parallel large units must not push in continuous contact around the corner (%.2f s)" \
			% (float(longest_contact_streak) * MatchClockScript.SECONDS_PER_TICK))
	for assignment in assignments:
		var unit: Node3D = assignment["unit"]
		_expect(unit.global_position.distance_to(navigation.agent_debug(unit)["destination"]) < 1.0,
			"every large unit using the shared corner must reach its destination")

	navigation.queue_free()
	inner.queue_free()
	outer.queue_free()


## Destinations are always the center of a free `size x size` cell block: odd
## footprints center on a cell, even footprints on a shared cell corner, and
## the blocks of one command never overlap.
func _test_grid_aligned_slots(grid: MapNavigationGrid) -> void:
	var navigation := NavigationSystemScript.new()
	root.add_child(navigation)
	_expect(navigation.setup(grid), "navigation system must initialize")

	var units: Array[Node3D] = []
	for index in 3:
		var small := FakeUnit.new(1.0)
		root.add_child(small)
		small.global_position = Vector3(140.0 + float(index), 0.0, 140.0)
		units.append(small)
	for index in 2:
		var large := FakeUnit.new(2.0)
		root.add_child(large)
		large.global_position = Vector3(140.0 + float(index) * 2.0, 0.0, 143.0)
		units.append(large)
	navigation.command_move(units, Vector3(150.7, 0.0, 150.2), NavConstantsScript.MoveMode.FREE)
	_advance_navigation(navigation, 15.0)

	var blocks: Array[Dictionary] = []
	for unit in units:
		var span := int(navigation._agents[unit.get_instance_id()]["footprint"])
		var position: Vector3 = navigation.agent_debug(unit)["destination"]
		var expected := 0.5 if span % 2 == 1 else 0.0
		_expect(
			absf(fposmod(position.x, 1.0) - expected) < 0.001 and absf(fposmod(position.z, 1.0) - expected) < 0.001,
			"a claimed block for footprint %d must be a grid block center (got %.2f, %.2f)" % [span, position.x, position.z]
		)
		_expect(unit.global_position.distance_to(position) < 0.6, "every unit must settle on its claimed block")
		blocks.append({"anchor": navigation._parking_anchor(position, span), "span": span})
	for a in blocks.size():
		for b in range(a + 1, blocks.size()):
			_expect(
				not navigation._blocks_conflict(blocks[a]["anchor"], blocks[a]["span"], blocks[b]["anchor"], blocks[b]["span"]),
				"claimed footprint blocks must keep a one-cell gap"
			)

	navigation.queue_free()
	for unit in units:
		unit.queue_free()


## Collision is elastic: two units dropped on top of each other must be pushed
## apart by the separation force until they no longer overlap.
func _test_overlap_is_squeezed_out(grid: MapNavigationGrid) -> void:
	var navigation := NavigationSystemScript.new()
	root.add_child(navigation)
	_expect(navigation.setup(grid), "navigation system must initialize")

	var first := FakeUnit.new()
	var second := FakeUnit.new()
	root.add_child(first)
	root.add_child(second)
	first.global_position = Vector3(200.5, 0.0, 200.5)
	second.global_position = Vector3(200.6, 0.0, 200.5)
	navigation.register_unit(first)
	navigation.register_unit(second)
	_advance_navigation(navigation, 3.0)
	var contact := float(navigation._agents[first.get_instance_id()]["radius"]) \
		+ float(navigation._agents[second.get_instance_id()]["radius"])
	_expect(first.global_position.distance_to(second.global_position) >= contact - 0.01,
		"overlapping units must be squeezed apart (ended %.2f apart)" % first.global_position.distance_to(second.global_position))

	navigation.queue_free()
	first.queue_free()
	second.queue_free()


## Hold position is a hard ownership of the current point. Overlap recovery may
## move the other friendly (for example one arriving behind a refinery), but it
## must not dislodge a harvester while that harvester unloads on its dock.
func _test_hold_position_resists_separation(grid: MapNavigationGrid) -> void:
	var navigation := NavigationSystemScript.new()
	root.add_child(navigation)
	_expect(navigation.setup(grid), "navigation system must initialize")

	var held := FakeUnit.new()
	var overlapping := FakeUnit.new()
	root.add_child(held)
	root.add_child(overlapping)
	held.global_position = Vector3(210.5, 0.0, 210.5)
	overlapping.global_position = Vector3(210.6, 0.0, 210.5)
	navigation.register_unit(held)
	navigation.register_unit(overlapping)
	navigation.set_hold_position(held, true)
	var held_position := held.global_position
	var contact := float(navigation._agents[held.get_instance_id()]["radius"]) \
		+ float(navigation._agents[overlapping.get_instance_id()]["radius"])
	_expect(held.global_position.distance_to(overlapping.global_position) < contact,
		"hold-position fixture must begin with overlapping agents")

	_advance_navigation(navigation, 3.0)
	_expect(held.global_position.is_equal_approx(held_position),
		"separation must not displace a held unit")
	_expect(held.global_position.distance_to(overlapping.global_position) >= contact - 0.01,
		"the non-held unit must still separate from a held unit")

	navigation.queue_free()
	held.queue_free()
	overlapping.queue_free()


## The regression this exists for: a unit that stopped to shoot used to be a
## merely-idle neighbour, so elastic separation shoved it off its spot, its
## reserved destination walked it back, and the fire clip restarted every time.
func _test_firing_anchor_resists_separation(grid: MapNavigationGrid) -> void:
	var navigation := NavigationSystemScript.new()
	root.add_child(navigation)
	_expect(navigation.setup(grid), "navigation system must initialize")

	var shooter := FakeUnit.new()
	var arriving := FakeUnit.new()
	root.add_child(shooter)
	root.add_child(arriving)
	shooter.global_position = Vector3(180.5, 0.0, 180.5)
	arriving.global_position = Vector3(180.6, 0.0, 180.5)
	navigation.register_unit(shooter)
	navigation.register_unit(arriving)
	navigation.set_firing_anchor(shooter, true)
	var anchored_position := shooter.global_position
	var contact := float(navigation._agents[shooter.get_instance_id()]["radius"]) \
		+ float(navigation._agents[arriving.get_instance_id()]["radius"])
	_expect(shooter.global_position.distance_to(arriving.global_position) < contact,
		"firing-anchor fixture must begin with overlapping agents")

	_advance_navigation(navigation, 3.0)
	_expect(shooter.global_position.is_equal_approx(anchored_position),
		"separation must not displace a unit standing on its firing position")
	_expect(shooter.global_position.distance_to(arriving.global_position) >= contact - 0.01,
		"the arriving unit must still separate itself from a firing unit")

	# Unlike hold, the anchor is not a permanent pin: any accepted move order
	# releases it, which is how the attack pursuit resumes when the target runs.
	navigation.command_move([shooter], Vector3(190.5, 0.0, 180.5))
	_expect(not bool(navigation._agents[shooter.get_instance_id()]["firing_anchor"]),
		"a fresh move order must release the firing anchor")

	navigation.queue_free()
	shooter.queue_free()
	arriving.queue_free()


## Every member of an attack command used to run the same target-centred perch
## search and converge on the same cell. The arc is what stops the first
## arrivals from walling the rest out of weapon range.
func _test_attack_arc_spreads_a_group(grid: MapNavigationGrid) -> void:
	var navigation := NavigationSystemScript.new()
	root.add_child(navigation)
	_expect(navigation.setup(grid), "navigation system must initialize")

	var target := Vector3(120.5, 0.0, 120.5)
	var squad: Array[Node3D] = []
	for index in 5:
		var unit := FakeUnit.new()
		root.add_child(unit)
		# One file abreast, approaching the target from +Z.
		unit.global_position = Vector3(118.5 + float(index), 0.0, 132.5)
		navigation.register_unit(unit)
		squad.append(unit)
	var assigned := navigation.assign_attack_arcs(squad, target, 12.0)
	_expect(assigned.size() == squad.size(), "every ground shooter must receive an arc slot")

	var bearings: Array[float] = []
	for unit in squad:
		var direction: Vector3 = (unit as FakeUnit).attack_arc_direction
		_expect(direction.is_normalized() and is_zero_approx(direction.y),
			"an arc slot must be a horizontal unit bearing")
		bearings.append(atan2(direction.z, direction.x))
	var minimum_separation := INF
	for a_index in bearings.size():
		for b_index in range(a_index + 1, bearings.size()):
			minimum_separation = minf(
				minimum_separation, absf(angle_difference(bearings[a_index], bearings[b_index]))
			)
	_expect(minimum_separation > 0.01,
		"no two units may be sent to the same bearing around the target")

	# The group approaches from +Z, so every slot must stay on that side: an arc
	# wider than a half-circle would walk units around a target that shoots back.
	var approach := atan2(1.0, 0.0)
	var widest := 0.0
	for bearing in bearings:
		widest = maxf(widest, absf(angle_difference(approach, bearing)))
	_expect(widest <= PI * 0.5 + 0.001,
		"the firing arc must stay within a half-circle of the approach side")

	# Slots follow the order the units already stand in: a unit on the
	# counter-clockwise flank must not be sent to the clockwise one, or the two
	# flanks trade places and cross the whole crowd on the way to their slots.
	for unit in squad:
		var offset := unit.global_position - target
		offset.y = 0.0
		var start_side := angle_difference(approach, atan2(offset.z, offset.x))
		if absf(start_side) < 0.001:
			continue
		var slot: Vector3 = (unit as FakeUnit).attack_arc_direction
		var slot_side := angle_difference(approach, atan2(slot.z, slot.x))
		_expect(
			absf(slot_side) < 0.001 or signf(slot_side) == signf(start_side),
			"an arc slot must stay on the flank the unit already occupies"
		)

	navigation.queue_free()
	for unit in squad:
		unit.queue_free()


## reachable_attack_position() answers "nearest cell to the target", which is
## the same answer for everyone. reachable_firing_position() answers "nearest
## legal cell to my own slot", and refuses a cell already held by a shooter.
func _test_firing_position_follows_its_arc_slot(grid: MapNavigationGrid) -> void:
	var navigation := NavigationSystemScript.new()
	root.add_child(navigation)
	_expect(navigation.setup(grid), "navigation system must initialize")

	var target := Vector3(140.5, 0.0, 140.5)
	var unit := FakeUnit.new()
	root.add_child(unit)
	unit.global_position = Vector3(140.5, 0.0, 160.5)
	navigation.register_unit(unit)

	var maximum_range := 30.0
	var preferred_range := 16.0
	var centred := navigation.reachable_attack_position(unit, target, maximum_range)
	_expect(
		Vector2(centred.x - target.x, centred.z - target.z).length() <= 2.0,
		"the target-centred search must still return a cell next to the target"
	)

	var slot := target + Vector3.RIGHT * preferred_range
	var perch := navigation.reachable_firing_position(
		unit, target, maximum_range, Vector3.RIGHT, preferred_range
	)
	_expect(perch.is_finite(), "an unobstructed arc slot must yield a firing position")
	_expect(
		Vector2(perch.x - slot.x, perch.z - slot.z).length() <= 2.0,
		"the firing position must land on the requested arc slot, not next to the target"
	)
	_expect(
		Vector2(perch.x - target.x, perch.z - target.z).length() <= maximum_range,
		"an arc slot outside weapon range must still be pulled inside it"
	)

	# A squadmate already anchored on that exact slot must push the search off
	# it: choosing the cell behind a firing unit is what both blocked the second
	# rank and put its shot through the first rank's back.
	var occupant := FakeUnit.new()
	root.add_child(occupant)
	occupant.global_position = slot
	navigation.register_unit(occupant)
	navigation.set_firing_anchor(occupant, true)
	var contact := float(navigation._agents[unit.get_instance_id()]["radius"]) \
		+ float(navigation._agents[occupant.get_instance_id()]["radius"])
	var displaced := navigation.reachable_firing_position(
		unit, target, maximum_range, Vector3.RIGHT, preferred_range
	)
	_expect(displaced.is_finite(), "an occupied arc slot must still yield a firing position")
	_expect(
		Vector2(displaced.x - slot.x, displaced.z - slot.z).length() >= contact,
		"a firing position must not overlap a squadmate already anchored on that slot"
	)

	# A unit with no arc assigned keeps the previous target-centred behaviour.
	var unslotted := navigation.reachable_firing_position(
		unit, target, maximum_range, Vector3.ZERO, preferred_range
	)
	_expect(unslotted.is_equal_approx(centred),
		"without an arc slot the firing search must fall back to the target-centred one")

	navigation.queue_free()
	unit.queue_free()
	occupant.queue_free()


## A combat-deployed unit (Kindjal/Mortar/Kobra) drives the same
## set_hold_position seam as the generic hold-position fixture above, through
## Unit.deploy()/finish_deployment() rather than a direct navigation call.
func _test_combat_deployed_unit_resists_displacement(grid: MapNavigationGrid) -> void:
	var navigation := NavigationSystemScript.new()
	root.add_child(navigation)
	_expect(navigation.setup(grid), "navigation system must initialize")

	var kindjal := UnitScene.instantiate() as Unit
	kindjal.config_id = &"ATKindjal"
	root.add_child(kindjal)
	kindjal.replace_visual_scene(ATKindjalModelScene)
	kindjal.global_position = Vector3(210.5, 0.0, 210.5)
	kindjal.set_navigation_controller(navigation)
	navigation.register_unit(kindjal)

	_expect(kindjal.deploy(), "a travel-mode Kindjal must accept the deploy command")
	kindjal.finish_deployment(true)
	_expect(kindjal.is_deployed(), "the deploy call must land the Kindjal in DEPLOYED")

	var approaching := FakeUnit.new()
	root.add_child(approaching)
	approaching.global_position = Vector3(210.6, 0.0, 210.5)
	navigation.register_unit(approaching)

	var deployed_position := kindjal.global_position
	var contact := float(navigation._agents[kindjal.get_instance_id()]["radius"]) \
		+ float(navigation._agents[approaching.get_instance_id()]["radius"])
	_expect(
		kindjal.global_position.distance_to(approaching.global_position) < contact,
		"deployed-unit fixture must begin with overlapping agents"
	)

	_advance_navigation(navigation, 3.0)
	_expect(
		kindjal.global_position.is_equal_approx(deployed_position),
		"a deployed unit must not be displaced by another unit steered into it"
	)
	_expect(
		kindjal.global_position.distance_to(approaching.global_position) >= contact - 0.01,
		"the approaching unit must still separate from the deployed unit"
	)

	navigation.queue_free()
	kindjal.queue_free()
	approaching.queue_free()


## Large unit discs can overlap while their centres are more than one spatial
## bucket apart; neighbour lookup must expand with their collision radii.
func _test_large_overlap_spans_spatial_buckets(grid: MapNavigationGrid) -> void:
	var navigation := NavigationSystemScript.new()
	root.add_child(navigation)
	_expect(navigation.setup(grid), "navigation system must initialize")

	var first := FakeUnit.new(5.0)
	var second := FakeUnit.new(5.0)
	root.add_child(first)
	root.add_child(second)
	first.global_position = Vector3(39.9, 0.0, 220.5)
	second.global_position = Vector3(44.0, 0.0, 220.5)
	navigation.register_unit(first)
	navigation.register_unit(second)
	var contact := float(navigation._agents[first.get_instance_id()]["radius"]) \
		+ float(navigation._agents[second.get_instance_id()]["radius"])
	_expect(first.global_position.distance_to(second.global_position) < contact,
		"large-unit fixture must begin overlapped across non-adjacent buckets")
	_advance_navigation(navigation, 4.0)
	_expect(first.global_position.distance_to(second.global_position) >= contact - 0.01,
		"large overlapping units in distant buckets must still separate")

	navigation.queue_free()
	first.queue_free()
	second.queue_free()


## A third unit may push a friend toward an enemy, but the post-steering
## separation velocity must still respect the enemy's solid swept disc.
func _test_enemy_stays_solid_under_separation(grid: MapNavigationGrid) -> void:
	var navigation := NavigationSystemScript.new()
	root.add_child(navigation)
	_expect(navigation.setup(grid), "navigation system must initialize")

	var pusher := FakeUnit.new()
	var squeezed := FakeUnit.new()
	var enemy := FakeUnit.new()
	enemy.owner_player_id = 2
	root.add_child(pusher)
	root.add_child(squeezed)
	root.add_child(enemy)
	pusher.global_position = Vector3(179.5, 0.0, 180.5)
	squeezed.global_position = Vector3(180.0, 0.0, 180.5)
	enemy.global_position = Vector3(180.9, 0.0, 180.5)
	navigation.register_unit(pusher)
	navigation.register_unit(squeezed)
	navigation.register_unit(enemy)
	var contact := float(navigation._agents[squeezed.get_instance_id()]["radius"]) \
		+ float(navigation._agents[enemy.get_instance_id()]["radius"])
	var closest_approach := squeezed.global_position.distance_to(enemy.global_position)
	for _iteration in _navigation_tick_count(4.0):
		navigation.call("_navigation_tick")
		closest_approach = minf(closest_approach, squeezed.global_position.distance_to(enemy.global_position))
	_expect(closest_approach >= contact - 0.01,
		"friendly separation must not push a unit through an enemy (closest %.2f, contact %.2f)" % [closest_approach, contact])
	_expect(squeezed.global_position.x < enemy.global_position.x,
		"a friend pushed toward an enemy must remain on its original side")

	navigation.queue_free()
	pusher.queue_free()
	squeezed.queue_free()
	enemy.queue_free()


## Elastic crowding in a corridor one cell wide: two units meeting head-on
## cannot steer around each other, so they compress, slide through, and get
## expelled on the far side — a hard-collision model deadlocks here.
func _test_elastic_corridor_pass(grid: MapNavigationGrid) -> void:
	var navigation := NavigationSystemScript.new()
	root.add_child(navigation)
	_expect(navigation.setup(grid), "navigation system must initialize")
	var walls := {}
	for x in range(60, 71):
		walls[Vector2i(x, 199)] = true
		walls[Vector2i(x, 201)] = true
	navigation.runtime_map.replace_blocked_cells(walls)

	var east_bound := FakeUnit.new()
	var west_bound := FakeUnit.new()
	root.add_child(east_bound)
	root.add_child(west_bound)
	east_bound.global_position = Vector3(58.5, 0.0, 200.5)
	west_bound.global_position = Vector3(72.5, 0.0, 200.5)
	var east_target := Vector3(72.5, 0.0, 200.5)
	var west_target := Vector3(58.5, 0.0, 200.5)
	navigation.command_move([east_bound], east_target)
	navigation.command_move([west_bound], west_target)
	var closest_approach := INF
	var fastest_step := 0.0
	var previous_east := east_bound.global_position
	var previous_west := west_bound.global_position
	for _iteration in _navigation_tick_count(12.0):
		navigation.call("_navigation_tick")
		closest_approach = minf(closest_approach, east_bound.global_position.distance_to(west_bound.global_position))
		fastest_step = maxf(fastest_step, maxf(
			previous_east.distance_to(east_bound.global_position) / MatchClockScript.SECONDS_PER_TICK,
			previous_west.distance_to(west_bound.global_position) / MatchClockScript.SECONDS_PER_TICK
		))
		previous_east = east_bound.global_position
		previous_west = west_bound.global_position
	_expect(east_bound.global_position.distance_to(east_target) < 1.5,
		"the east-bound unit must squeeze past in the corridor (ended %.1f,%.1f)" % [east_bound.global_position.x, east_bound.global_position.z])
	_expect(west_bound.global_position.distance_to(west_target) < 1.5,
		"the west-bound unit must squeeze past in the corridor (ended %.1f,%.1f)" % [west_bound.global_position.x, west_bound.global_position.z])
	var corridor_contact := float(navigation._agents[east_bound.get_instance_id()]["radius"]) \
		+ float(navigation._agents[west_bound.get_instance_id()]["radius"])
	_expect(closest_approach < corridor_contact * 0.75,
		"corridor pass must use soft overlap, not an accidental detour (closest %.2f)" % closest_approach)
	_expect(fastest_step <= east_bound.move_speed + 0.01,
		"steering plus separation must not exceed unit speed (observed %.2f)" % fastest_step)

	navigation.queue_free()
	east_bound.queue_free()
	west_bound.queue_free()


## The point of the parking gap: a single unit ordered to the far side of a
## standing formation threads the free lanes between parked blocks instead of
## being walled out.
func _test_lane_through_standing_formation(grid: MapNavigationGrid) -> void:
	var navigation := NavigationSystemScript.new()
	root.add_child(navigation)
	_expect(navigation.setup(grid), "navigation system must initialize")

	var formation: Array[FakeUnit] = []
	for index in 9:
		var unit := FakeUnit.new()
		root.add_child(unit)
		unit.global_position = Vector3(148.5 + float(index % 3), 0.0, 148.5 + float(index / 3))
		formation.append(unit)
	navigation.command_move(formation, Vector3(150.5, 0.0, 150.5), NavConstantsScript.MoveMode.FREE)
	_advance_navigation(navigation, 10.0)

	var runner := FakeUnit.new()
	root.add_child(runner)
	runner.global_position = Vector3(150.5, 0.0, 140.5)
	var far_side := Vector3(150.5, 0.0, 160.5)
	navigation.command_move([runner], far_side)
	_advance_navigation(navigation, 10.0)
	_expect(runner.global_position.distance_to(far_side) < 1.5,
		"a single unit must cross a standing formation through its parking lanes (ended %.1f,%.1f)" % [
			runner.global_position.x, runner.global_position.z])

	navigation.queue_free()
	for unit in formation:
		unit.queue_free()
	runner.queue_free()


## Four large round units meet at one point from reciprocal directions. A
## stable passing-side bias and soft personal fields must resolve the crossing
## once, rather than making the group retry alternating detours for many cycles.
func _test_large_reciprocal_crossing(grid: MapNavigationGrid) -> void:
	var navigation := NavigationSystemScript.new()
	root.add_child(navigation)
	_expect(navigation.setup(grid), "navigation system must initialize for large-unit crossing")
	var center := Vector3(170.5, 0.0, 170.5)
	var starts := [
		center + Vector3(-12.0, 0.0, 0.0),
		center + Vector3(12.0, 0.0, 0.0),
		center + Vector3(0.0, 0.0, -12.0),
		center + Vector3(0.0, 0.0, 12.0),
	]
	var targets := [starts[1], starts[0], starts[3], starts[2]]
	var units: Array[FakeUnit] = []
	for index in starts.size():
		var unit := FakeUnit.new(3.0)
		root.add_child(unit)
		unit.global_position = starts[index]
		units.append(unit)
		navigation.command_move([unit], targets[index])
	var settled_tick := _navigation_tick_count(16.0)
	for tick in range(1, settled_tick + 1):
		navigation.call("_navigation_tick")
		if units.all(func(unit: FakeUnit) -> bool:
			return unit.global_position.distance_to(
				navigation.agent_debug(unit)["destination"]
			) < 1.0
		):
			settled_tick = tick
			break
	_expect(
		settled_tick < _navigation_tick_count(12.0),
		"four reciprocal size-three units must settle after one bounded avoidance manoeuvre (%.1f s)" \
			% (float(settled_tick) * MatchClockScript.SECONDS_PER_TICK)
	)
	for unit in units:
		_expect(
			unit.global_position.distance_to(navigation.agent_debug(unit)["destination"]) < 1.0,
			"every large unit in the reciprocal crossing must reach its destination"
		)

	navigation.queue_free()
	for unit in units:
		unit.queue_free()


## 21 units ringed around a point are all ordered into its center — the worst
## head-on convergence. Reports how long the scrum lasts and how many of the
## originally planned slots end up empty; the group must settle, not churn.
func _test_circle_convergence_metrics(grid: MapNavigationGrid) -> void:
	var navigation := NavigationSystemScript.new()
	root.add_child(navigation)
	_expect(navigation.setup(grid), "navigation system must initialize")

	var center := Vector3(100.5, 0.0, 100.5)
	var units: Array[FakeUnit] = []
	for index in 21:
		var unit := FakeUnit.new()
		root.add_child(unit)
		var angle := TAU * float(index) / 21.0
		unit.global_position = center + Vector3(cos(angle), 0.0, sin(angle)) * 12.0
		units.append(unit)
	navigation.command_move(units, center, NavConstantsScript.MoveMode.FREE)

	var tick_seconds := MatchClockScript.SECONDS_PER_TICK
	# 120 s budget, 5 s idle-settle window: durations, converted to ticks at
	# the simulation rate rather than hardcoded against the old 20 Hz.
	var max_ticks := _navigation_tick_count(120.0)
	var idle_ticks_to_finish := _navigation_tick_count(5.0)
	var previous: Array[Vector3] = []
	for unit in units:
		previous.append(unit.global_position)
	var last_active_tick := 0
	var elapsed_ticks := max_ticks
	for tick in range(1, max_ticks + 1):
		navigation.call("_navigation_tick")
		var moved := false
		for index in units.size():
			if units[index].global_position.distance_to(previous[index]) > 0.005:
				moved = true
			previous[index] = units[index].global_position
		if moved:
			last_active_tick = tick
		elif tick - last_active_tick >= idle_ticks_to_finish:
			elapsed_ticks = tick
			break

	var crowd_radius := 0.0
	for unit in units:
		var destination: Vector3 = navigation.agent_debug(unit)["destination"]
		_expect(unit.global_position.distance_to(destination) < 0.6, "every converging unit must settle on its claimed block")
		crowd_radius = maxf(crowd_radius, unit.global_position.distance_to(center))
	var holes := 0
	var center_cell: Vector2i = grid.world_to_grid(center)
	var scan := int(ceil(crowd_radius)) + 1
	for y in range(-scan, scan + 1):
		for x in range(-scan, scan + 1):
			var point: Vector3 = grid.grid_to_world(center_cell + Vector2i(x, y))
			if point.distance_to(center) >= crowd_radius:
				continue
			var covered := false
			for unit in units:
				if unit.global_position.distance_to(point) < 0.71:
					covered = true
					break
			if not covered:
				holes += 1
	print("Circle convergence: settled in %.1f s, crowd radius %.1f (gapped ideal ~5.2), %d empty cells inside the crowd" % [
		float(last_active_tick) * tick_seconds, crowd_radius, holes])
	_expect(elapsed_ticks < max_ticks, "the convergence scrum must settle, not churn forever")
	_expect(float(last_active_tick) * tick_seconds < 30.0, "21 units converging on one point must settle within 30 seconds")
	_expect(crowd_radius < 7.0, "21 units must pack near the target on the gapped lattice")

	navigation.queue_free()
	for unit in units:
		unit.queue_free()


## Jostling units carry a constantly refreshed yield. A fresh move order must
## cancel it: a stale yield steers the unit aside and, on expiry, replaces the
## ordered destination with wherever the unit stands — the order is ignored.
func _test_command_overrides_yield(grid: MapNavigationGrid) -> void:
	var navigation := NavigationSystemScript.new()
	root.add_child(navigation)
	_expect(navigation.setup(grid), "navigation system must initialize")

	var unit := FakeUnit.new()
	root.add_child(unit)
	unit.global_position = Vector3(120.5, 0.0, 120.5)
	navigation.command_move([unit], unit.global_position)
	navigation.call("_request_yield", unit, Vector3.RIGHT)
	_advance_navigation(navigation, 0.2)
	var destination := Vector3(130.5, 0.0, 130.5)
	navigation.command_move([unit], destination)
	_advance_navigation(navigation, 5.0)
	_expect(unit.global_position.distance_to(destination) < 1.0, "an order issued mid-yield must still be executed")

	navigation.queue_free()
	unit.queue_free()


## A vertical wall at x=30 with an opening at y 126..130, plus a wall at x=60
## with a single-cell gap at y=128 for clearance checks.
func _wall_cells() -> Dictionary:
	var walls := {}
	for y in MapNavigationGrid.NAV_SIZE:
		if y < 126 or y > 130:
			walls[Vector2i(30, y)] = true
		if y != 128:
			walls[Vector2i(60, y)] = true
	return walls


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
