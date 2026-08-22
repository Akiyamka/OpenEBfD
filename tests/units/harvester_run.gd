extends SceneTree

const UnitScript := preload("res://scripts/units/unit.gd")
const HarvesterControllerScript := preload("res://scripts/units/harvester_controller.gd")
const HarvesterScene := preload("res://scenes/units/harvester.tscn")
const UnitRosterControllerScript := preload("res://scripts/units/unit_roster_controller.gd")
const SelectionHaloScript := preload("res://scripts/ui/selection_halo.gd")
const MatchSnapshotScript := preload("res://scripts/match/match_snapshot.gd")
const NavigationSystemScript := preload("res://scripts/units/navigation/unit_navigation_system.gd")
const MatchClockScript := preload("res://scripts/sim/match_clock.gd")

var _assertions := 0
var _failures := 0
var _current_case := ""
var _completion_token := 1000


class FakeGrid extends RefCounted:
	func grid_to_world(cell: Vector2i, _centered := true) -> Vector3:
		return Vector3(float(cell.x) + 0.5, 0.0, float(cell.y) + 0.5)

	func world_to_grid(world_position: Vector3) -> Vector2i:
		return Vector2i(floori(world_position.x), floori(world_position.z))

	func cell_size() -> Vector2:
		return Vector2.ONE


class FakeSpiceLayer extends RefCounted:
	var values: Dictionary = {}

	func spice_at(cell: Vector2i) -> int:
		return int(values.get(cell, 0))

	func take_spice(cell: Vector2i, requested: int) -> int:
		var taken := mini(spice_at(cell), requested)
		values[cell] = spice_at(cell) - taken
		return taken

	func nearest_spice_cell(
			origin: Vector2i,
			minimum_amount := 1,
			maximum_distance := -1,
			candidate_filter := Callable()
		) -> Vector2i:
		var best := Vector2i(-1, -1)
		var best_distance := 0x7fffffff
		for candidate_variant in values:
			var candidate: Vector2i = candidate_variant
			if spice_at(candidate) < minimum_amount:
				continue
			var distance := origin.distance_squared_to(candidate)
			if maximum_distance >= 0 and distance > maximum_distance * maximum_distance:
				continue
			if candidate_filter.is_valid() and not bool(candidate_filter.call(candidate)):
				continue
			if distance < best_distance:
				best = candidate
				best_distance = distance
		return best


class TestHarvester extends UnitScript:
	var move_targets: Array[Vector3] = []
	var animation_log: Array[StringName] = []
	var stop_count := 0

	func _ready() -> void:
		pass

	func move_to(world_position: Vector3, _exit_point := Vector3.INF) -> void:
		move_targets.append(world_position)
		super.move_to(world_position, _exit_point)

	func stop_at_current_position() -> void:
		stop_count += 1
		target_position = global_position
		if _navigation_managed and _navigation_system != null:
			_navigation_system.stop(self)

	func navigation_collision_radius(fallback: float) -> float:
		return fallback

	# Stands in for the authored clips: records what was played and reports a
	# duration per clip. The two hold clips differ on purpose -- the harvest
	# hold has no authored length, so its interval must come from
	# HARVEST_HOLD_SECONDS, while the unload hold is timed by the clip itself.
	func play_action_animation(animation_name: StringName) -> float:
		animation_log.append(animation_name)
		if animation_name == HarvesterControllerScript.HARVEST_HOLD_ANIMATION:
			return 0.0
		return 0.5 \
			if animation_name == HarvesterControllerScript.UNLOAD_HOLD_ANIMATION else 0.1


class FakeNavigation extends RefCounted:
	enum MoveMode { FREE, FORMATION }
	var held: Dictionary = {}
	var dock_targets: Array[Vector3] = []
	var departure_targets: Array[Vector3] = []
	var move_targets: Array[Vector3] = []

	func command_move(_units: Array, _target: Vector3, _mode: int, _exit_point := Vector3.INF) -> Array[Dictionary]:
		move_targets.append(_target)
		for unit in _units:
			unit.set_navigation_destination(_target + Vector3(0.0, 0.0, 2.0))
		return []

	func command_dock(unit: Node3D, target: Vector3, _allowed_cells: Dictionary) -> bool:
		dock_targets.append(target)
		unit.set_navigation_destination(target)
		return true

	func command_depart(unit: Node3D, target: Vector3, _allowed_cells: Dictionary) -> bool:
		departure_targets.append(target)
		unit.set_navigation_destination(target)
		return true

	func stop(_unit: Node3D) -> void:
		pass

	func set_hold_position(unit: Node3D, active: bool) -> void:
		held[unit] = active

	func is_held(unit: Node3D) -> bool:
		return bool(held.get(unit, false))

	func arrival_tolerance(_unit: Node3D) -> float:
		return 0.5


class FakeRefinery extends Node3D:
	var owner_player_id := 1
	var available := true
	var reserved_by: Node = null
	var release_delays: Array[float] = []
	var abandoned := 0
	var front := Vector3.ZERO
	var dock := Vector3(2.0, 0.0, 0.0)
	var rally_point := Vector3.ZERO

	func is_refinery() -> bool:
		return true

	func is_owned_by(player_id: int) -> bool:
		return owner_player_id == player_id

	func refinery_front_position() -> Vector3:
		return front

	func rally_point_position() -> Vector3:
		return rally_point

	func try_reserve_refinery_dock(harvester: Node) -> int:
		if not available or reserved_by != null:
			return -1
		reserved_by = harvester
		return 0

	func refinery_dock_reserved_by(_dock_index: int, harvester: Node) -> bool:
		return reserved_by == harvester

	func refinery_dock_world_position(_dock_index: int) -> Vector3:
		return dock

	func refinery_dock_facing_direction(_dock_index: int) -> Vector3:
		return Vector3.BACK

	func refinery_dock_navigation_cells(_grid) -> Dictionary:
		return {Vector2i(1, 1): "d"}

	func release_refinery_dock(harvester: Node, cooldown_seconds := 3.0) -> void:
		if reserved_by == harvester:
			reserved_by = null
		release_delays.append(cooldown_seconds)

	func abandon_refinery_dock(harvester: Node) -> void:
		if reserved_by == harvester:
			reserved_by = null
			abandoned += 1


class FakeMainBase extends Node3D:
	var owner_player_id := 1

	func is_owned_by(player_id: int) -> bool:
		return owner_player_id == player_id


class FakeMultiDockRefinery extends FakeRefinery:
	var reservations: Dictionary = {}
	var dock_positions := [Vector3.ZERO, Vector3(-6.0, 0.0, 2.0)]

	func try_reserve_refinery_dock(harvester: Node) -> int:
		for dock_index in dock_positions.size():
			if not reservations.has(dock_index):
				reservations[dock_index] = harvester
				return dock_index
		return -1

	func refinery_dock_reserved_by(dock_index: int, harvester: Node) -> bool:
		return reservations.get(dock_index) == harvester

	func refinery_dock_world_position(dock_index: int) -> Vector3:
		return dock_positions[dock_index]

	func release_refinery_dock(harvester: Node, cooldown_seconds := 3.0) -> void:
		for dock_index in reservations.keys():
			if reservations[dock_index] == harvester:
				reservations.erase(dock_index)
		release_delays.append(cooldown_seconds)

	func abandon_refinery_dock(harvester: Node) -> void:
		for dock_index in reservations.keys():
			if reservations[dock_index] == harvester:
				reservations.erase(dock_index)
		abandoned += 1


class FakeCargoEntity extends Node3D:
	var health := 1.0
	var max_health := 1.0
	var shields := 0.0
	var max_shields := 0.0
	var spice := 350.0
	var max_spice := 700.0
	var passengers := 0.0
	var max_passengers := 0.0


func _initialize() -> void:
	await process_frame
	var players = root.get_node("Players")
	players.reset_for_match()
	var local_player = players.create_player(1, "Harvester Tester", Color.BLUE, &"Atreides", [], 1, 0, 0)
	_run_case("rules capacity and @!Harv halo", _test_rules_capacity_and_halo)
	_run_case("cycle timing, extraction cap, and nearby retarget", _test_cycle_and_retarget)
	_run_case("empty arrival and map-wide continuation", _test_empty_arrival)
	_run_case("a crowded harvester group reaches and works the same spice field", _test_two_harvesters_share_field)
	_run_case("remaining bunker capacity limits extraction", _test_remaining_capacity)
	_run_case("Stop clears every harvester order and autonomous cycle", _test_stop_clears_all_orders.bind(local_player))
	_run_case("full harvesters automatically bind to the nearest owned refinery", _test_full_harvester_auto_unload.bind(local_player))
	_run_case("manual refinery binding persists and automatic fields honor visibility", _test_cycle_binding_and_spice_filter.bind(local_player))
	_run_case("unload rate transfers a full bunker in 17.5 seconds", _test_full_unload.bind(local_player))
	_run_case("unload waits for a free reserved dock", _test_unload_waits_for_dock.bind(local_player))
	_run_case("a free side dock is reserved before approaching the refinery", _test_side_dock_routes_directly.bind(local_player))
	_run_case("unload arrival uses the navigation tolerance", _test_unload_navigation_arrival.bind(local_player))
	_run_case("refinery rally point selects the next spice field", _test_refinery_rally_selects_next_field.bind(local_player))
	_run_case("unload parking respects the harvester turn rate", _test_unload_parking_turn_rate.bind(local_player))
	_run_case("direct orders finish unload animations before moving", _test_unload_interruption.bind(local_player))
	_run_case("refinery capture gracefully cancels unloading", _test_unload_refinery_capture.bind(local_player))
	players.reset_for_match()
	if _failures > 0:
		printerr("Harvester tests: %d failures after %d assertions" % [_failures, _assertions])
		quit(1)
		return
	print("Harvester tests: %d assertions passed" % _assertions)
	quit(0)


func _test_rules_capacity_and_halo(token: int) -> int:
	var harvester := TestHarvester.new()
	root.add_child(harvester)
	harvester.setup(&"Harvester")
	_expect(is_equal_approx(harvester.max_spice, 700.0), "runtime Harvester capacity must match local Rules.txt")
	var scene_harvester := HarvesterScene.instantiate()
	root.add_child(scene_harvester)
	_expect(
		scene_harvester is UnitScript and scene_harvester.can_harvest_spice(),
		"the dedicated Harvester scene must be an ordinary Unit that harvests"
	)
	var body_radius := float(scene_harvester.navigation_collision_radius(1.26))
	var rotation_radius := float(scene_harvester.navigation_rotation_radius(body_radius))
	_expect(rotation_radius > body_radius * 1.4,
		"harvester navigation must retain its long capsule envelope (width %.2f, rotation %.2f)" \
			% [body_radius, rotation_radius])
	var has_unload_clips := false
	for node in scene_harvester.find_children("*", "AnimationPlayer", true, false):
		var player := node as AnimationPlayer
		if player.has_animation(HarvesterControllerScript.UNLOAD_START_ANIMATION) \
		and player.has_animation(HarvesterControllerScript.UNLOAD_HOLD_ANIMATION) \
		and player.has_animation(HarvesterControllerScript.UNLOAD_END_ANIMATION):
			has_unload_clips = true
			break
	_expect(has_unload_clips, "the converted harvester model must retain all three unload clips")
	scene_harvester.free()
	var roster := UnitRosterControllerScript.new()
	var produced := roster._scene_for_unit(&"Harvester").instantiate()
	var ordinary := roster._scene_for_unit(&"ATInfantry").instantiate()
	root.add_child(produced)
	root.add_child(ordinary)
	_expect(
		produced is UnitScript and produced.can_harvest_spice()
		and ordinary is UnitScript and not ordinary.can_harvest_spice(),
		"unit production must choose the harvesting scene only for Harvester"
	)
	produced.free()
	ordinary.free()
	roster.free()
	harvester.spice = 210.0
	var snapshot := MatchSnapshotScript.new()
	var record: Dictionary = snapshot._capture_entity(harvester)
	harvester.spice = 0.0
	snapshot._restore_entity_details(harvester, record)
	_expect(is_equal_approx(harvester.spice, 210.0), "match snapshots must preserve collected harvester cargo")

	var cargo := FakeCargoEntity.new()
	root.add_child(cargo)
	var halo_anchor := Node3D.new()
	cargo.add_child(halo_anchor)
	var halo := SelectionHaloScript.new()
	cargo.add_child(halo)
	halo.configure(cargo, 1.0, Vector3.ZERO, halo_anchor)
	halo.set_selected(true)
	halo.set_movement_direction(Vector3.RIGHT)
	halo._process(0.0)
	var harvester_layer := halo.get_node("Transport") as MeshInstance3D
	var spice_layer := halo.get_node("Spice") as MeshInstance3D
	var movement_arrow := halo.get_node("MovementDirection") as MeshInstance3D
	var material := harvester_layer.material_override as ShaderMaterial
	_expect(harvester_layer.visible and not spice_layer.visible, "harvester cargo must use the authored @!Harv ring without a duplicate @!Spice ring")
	_expect(is_equal_approx(float(material.get_shader_parameter("fill")), 0.5), "@!Harv fill must track spice divided by bunker capacity")
	_expect(not movement_arrow.visible,
		"the final navigation course must remain hidden while debug layers are disabled")
	halo.set_movement_debug_visible(true)
	_expect(movement_arrow.visible and movement_arrow.mesh != null,
		"an enabled debug layer must expose the selected unit's final navigation course")
	var arrow_mesh: Mesh = movement_arrow.mesh
	for index in 40:
		var angle := TAU * float(index) / 40.0
		halo.set_movement_direction(Vector3(cos(angle), 0.0, sin(angle)))
	_expect(
		movement_arrow.mesh == arrow_mesh,
		"changing debug course arrows must refill one mesh instead of allocating GPU resources"
	)
	halo.set_movement_debug_visible(false)
	_expect(not movement_arrow.visible, "disabling debug layers must hide the navigation course arrow")
	halo.set_movement_debug_visible(true)
	halo.set_selected(false)
	_expect(not movement_arrow.visible, "the navigation course arrow must disappear with selection")
	halo_anchor.position = Vector3(0.25, 2.0, -0.5)
	halo._process(0.0)
	_expect(
		halo.position.is_equal_approx(halo_anchor.position),
		"the selection halo must follow its authored animated anchor"
	)
	harvester.queue_free()
	cargo.queue_free()
	return token


func _run_case(case_name: String, test: Callable) -> void:
	_current_case = case_name
	_completion_token += 1
	var token := _completion_token
	var failures_before := _failures
	var completed: Variant = test.call(token)
	if completed != token:
		_failures += 1
		printerr("FAIL: %s: case did not return its completion token" % case_name)
		return
	if _failures == failures_before:
		print("PASS: %s" % case_name)


func _test_stop_clears_all_orders(token: int, player: PlayerData) -> int:
	var grid := FakeGrid.new()
	var layer := FakeSpiceLayer.new()
	var field := Vector2i(8, 9)
	layer.values[field] = 100
	var refinery := FakeRefinery.new()
	refinery.owner_player_id = player.player_id
	root.add_child(refinery)
	var harvester := TestHarvester.new()
	harvester.owner_player_id = player.player_id
	harvester.max_spice = 700.0
	harvester.spice = 100.0
	root.add_child(harvester)

	_expect(
		harvester.command_harvest(layer, grid, field),
		"the Stop test must begin with an active harvest cycle"
	)
	_expect(harvester.has_active_order(), "harvesting must count as an active order before Stop")
	harvester.cancel_all_orders()
	_expect(
		not harvester._harvester.has_harvest_order()
		and not harvester._harvester.has_unload_order()
		and not harvester.has_active_order(),
		"Stop must clear harvesting, unloading, movement, and the autonomous cycle"
	)
	_expect(
		harvester.target_position.is_equal_approx(harvester.global_position),
		"Stop must leave the harvester at its current position"
	)

	_expect(
		harvester.command_unload(refinery, grid, layer),
		"the Stop test must begin with an active unload order"
	)
	_expect(
		harvester._harvester.has_unload_order() and harvester._harvester.assigned_refinery() == refinery,
		"manual unloading must retain its refinery binding before Stop"
	)
	harvester.cancel_all_orders()
	_expect(
		not harvester.has_active_order() and harvester._harvester.assigned_refinery() == null,
		"Stop must clear unloading and its persistent refinery binding"
	)
	_expect(refinery.reserved_by == null, "Stop must release an unloading dock reservation")

	harvester.queue_free()
	refinery.queue_free()
	return token


func _test_cycle_and_retarget(token: int) -> int:
	var grid := FakeGrid.new()
	var layer := FakeSpiceLayer.new()
	var first := Vector2i(10, 10)
	var second := Vector2i(13, 10)
	layer.values[first] = 140
	layer.values[second] = 200
	var harvester := TestHarvester.new()
	harvester.max_spice = 700.0
	root.add_child(harvester)
	harvester.global_position = grid.grid_to_world(first)

	_expect(harvester.command_harvest(layer, grid, first), "a configured harvester must accept a harvesting order")
	harvester._harvester.advance_harvest_order(0.0)
	_expect(harvester.animation_log == [HarvesterControllerScript.HARVEST_START_ANIMATION], "arrival must begin with Harv_Eat_Start")
	harvester._harvester.advance_harvest_order(0.1)
	_expect(harvester.animation_log.back() == HarvesterControllerScript.HARVEST_HOLD_ANIMATION, "start completion must enter Harv_Eat_Hold")
	harvester._harvester.advance_harvest_order(0.29)
	_expect(is_zero_approx(harvester.spice), "cargo must not change before the hold interval completes")
	harvester._harvester.advance_harvest_order(0.02)
	_expect(is_equal_approx(harvester.spice, 140.0) and layer.spice_at(first) == 0, "one cycle may collect exactly one fifth of the 700-unit bunker")
	_expect(harvester.animation_log.back() == HarvesterControllerScript.HARVEST_END_ANIMATION, "collection must be followed by Harv_Eat_End")
	harvester._harvester.advance_harvest_order(0.1)
	_expect(harvester._harvester.harvest_target_cell() == second, "an exhausted cell must switch to nearby spice")
	_expect(harvester.move_targets.back() == grid.grid_to_world(second), "retargeting must issue movement to the next cell")
	_expect(harvester._harvester.has_harvest_order(), "nearby spice must keep the autonomous order alive")
	harvester.queue_free()
	return token


func _test_empty_arrival(token: int) -> int:
	var grid := FakeGrid.new()
	var layer := FakeSpiceLayer.new()
	var empty := Vector2i(20, 20)
	var nearby := Vector2i(27, 20)
	layer.values[nearby] = 50
	var harvester := TestHarvester.new()
	harvester.max_spice = 700.0
	root.add_child(harvester)
	harvester.global_position = grid.grid_to_world(empty)
	harvester.command_harvest(layer, grid, empty)
	harvester._harvester.advance_harvest_order(0.0)
	_expect(harvester._harvester.harvest_target_cell() == nearby and harvester.animation_log.is_empty(), "an empty arrival must retarget before starting the collection animation")

	layer.values[nearby] = 0
	var distant := Vector2i(36, 20)
	layer.values[distant] = 100
	harvester.global_position = grid.grid_to_world(nearby)
	harvester._harvester.advance_harvest_order(0.0)
	_expect(harvester._harvester.has_harvest_order() and harvester._harvester.harvest_target_cell() == distant, "an unfinished bunker must continue at the nearest non-empty field even beyond the old local radius")
	layer.values[distant] = 0
	harvester.global_position = grid.grid_to_world(distant)
	harvester._harvester.advance_harvest_order(0.0)
	_expect(not harvester._harvester.has_harvest_order(), "the order must stop when the map has no remaining spice")
	_expect(harvester._harvester.harvest_target_cell() == Vector2i(-1, -1), "a completed order must clear its target")
	harvester.queue_free()
	return token


func _test_two_harvesters_share_field(token: int) -> int:
	var grid := _make_open_navigation_grid()
	var navigation := NavigationSystemScript.new()
	root.add_child(navigation)
	_expect(navigation.setup(grid), "the crowd-navigation fixture must initialize")
	var layer := FakeSpiceLayer.new()
	var field := Vector2i(60, 60)
	layer.values[field] = 100000
	var harvesters: Array[TestHarvester] = []
	for index in 6:
		var harvester := TestHarvester.new()
		harvester.config_id = &"Harvester"
		harvester.max_spice = 700.0
		harvester.move_speed = 4.0
		harvester.turn_rate = 0.15
		root.add_child(harvester)
		harvester.global_position = Vector3(
			40.5 + float(index % 2) * 2.0,
			0.0,
			54.5 + float(index / 2) * 2.0
		)
		navigation.register_unit(harvester)
		_expect(harvester.command_harvest(layer, grid, field), "each harvester must accept the shared field order")
		harvesters.append(harvester)
	# 75 s budget (1500 ticks at the old 20 Hz navigation tick), converted to
	# ticks at the simulation rate. advance_harvest_order() is a separate,
	# frame-delta-driven clock (see harvester_controller.gd) that this loop
	# happens to co-advance one simulated tick at a time for convenience, so
	# its per-iteration step moves to the same tick length to keep the two
	# in lockstep the way the old matching 0.05/0.05 pair did.
	for _tick in roundi(75.0 * float(MatchClockScript.TICKS_PER_SECOND)):
		navigation.call("_navigation_tick")
		for harvester in harvesters:
			harvester._harvester.advance_harvest_order(MatchClockScript.SECONDS_PER_TICK)
		if harvesters.all(func(harvester: TestHarvester) -> bool: return harvester.spice > 0.0):
			break
	_expect(
		harvesters.all(func(harvester: TestHarvester) -> bool: return harvester.spice > 0.0),
		"every large harvester must accept its safe parking position and begin collecting instead of waiting forever in TRAVEL; states=%s" % str(harvesters.map(
			func(harvester: TestHarvester) -> Dictionary: return {
				"position": harvester.global_position,
				"destination": harvester.target_position,
				"field": harvester._harvester.harvest_target_cell(),
				"spice": harvester.spice,
			}
		))
	)

	navigation.queue_free()
	for harvester in harvesters:
		harvester.queue_free()
	return token


func _test_remaining_capacity(token: int) -> int:
	var grid := FakeGrid.new()
	var layer := FakeSpiceLayer.new()
	var cell := Vector2i(4, 4)
	layer.values[cell] = 100
	var harvester := TestHarvester.new()
	harvester.max_spice = 100.0
	harvester.spice = 85.0
	root.add_child(harvester)
	harvester.global_position = grid.grid_to_world(cell)
	harvester.command_harvest(layer, grid, cell)
	harvester._harvester.advance_harvest_order(0.41)
	_expect(is_equal_approx(harvester.spice, 100.0), "a cycle must stop at the remaining bunker capacity")
	_expect(layer.spice_at(cell) == 85, "only the cargo actually loaded may be removed from the map cell")
	harvester._harvester.advance_harvest_order(0.1)
	_expect(not harvester._harvester.has_harvest_order(), "a full bunker must complete the harvesting order")
	harvester.queue_free()
	return token


func _test_full_harvester_auto_unload(token: int, player: PlayerData) -> int:
	var grid := FakeGrid.new()
	var layer := FakeSpiceLayer.new()
	var target_cell := Vector2i(4, 4)
	layer.values[target_cell] = 100
	# "sim_buildings" too, on all three: HarvesterController._nearest_owned_refinery()
	# reads that group, not "buildings", as of slice C6a
	# (scripts/units/harvester_controller.gd).
	var near_owned := FakeRefinery.new()
	near_owned.position = Vector3(5.0, 0.0, 0.0)
	near_owned.owner_player_id = player.player_id
	near_owned.add_to_group("buildings")
	near_owned.add_to_group("sim_buildings")
	root.add_child(near_owned)
	var far_owned := FakeRefinery.new()
	far_owned.position = Vector3(20.0, 0.0, 0.0)
	far_owned.owner_player_id = player.player_id
	far_owned.add_to_group("buildings")
	far_owned.add_to_group("sim_buildings")
	root.add_child(far_owned)
	var enemy := FakeRefinery.new()
	enemy.position = Vector3(1.0, 0.0, 0.0)
	enemy.owner_player_id = player.player_id + 1
	enemy.add_to_group("buildings")
	enemy.add_to_group("sim_buildings")
	root.add_child(enemy)
	var harvester := TestHarvester.new()
	harvester.owner_player_id = player.player_id
	harvester.max_spice = 100.0
	harvester.spice = 100.0
	root.add_child(harvester)
	var main_base := FakeMainBase.new()
	main_base.owner_player_id = player.player_id
	main_base.position = Vector3(40.0, 0.0, 0.0)
	root.add_child(main_base)
	root.get_node("Players").set_main_base(player.player_id, main_base)

	_expect(harvester.command_harvest(layer, grid, target_cell), "a full harvester must accept a harvest command as a request to continue its cycle")
	_expect(not harvester._harvester.has_harvest_order() and harvester._harvester.has_unload_order(), "a full bunker must skip field travel and immediately start unloading")
	_expect(harvester._harvester.assigned_refinery() == near_owned, "automatic unloading must bind the nearest owned refinery and ignore a closer enemy refinery")

	near_owned.owner_player_id = player.player_id + 1
	harvester._harvester.advance_unload_order(0.0)
	harvester._harvester.advance_harvest_cycle()
	_expect(harvester._harvester.assigned_refinery() == far_owned and harvester._harvester.has_unload_order(), "capture of the bound refinery must trigger a new nearest-owned search")

	far_owned.owner_player_id = player.player_id + 1
	harvester._harvester.advance_unload_order(0.0)
	harvester._harvester.advance_harvest_cycle()
	_expect(not harvester._harvester.has_unload_order() and harvester.target_position == main_base.global_position, "without an owned refinery a full harvester must return to the player's primary Construction Yard")
	near_owned.owner_player_id = player.player_id
	harvester._harvester.advance_harvest_cycle(HarvesterControllerScript.AUTO_SEARCH_RETRY_SECONDS)
	_expect(not harvester._harvester.has_unload_order() and harvester.target_position == main_base.global_position, "a refinery built later must not redirect a harvester returning to its main base")

	harvester.queue_free()
	near_owned.queue_free()
	far_owned.queue_free()
	enemy.queue_free()
	main_base.free()
	return token


func _test_cycle_binding_and_spice_filter(token: int, player: PlayerData) -> int:
	var grid := FakeGrid.new()
	var layer := FakeSpiceLayer.new()
	var hidden_cell := Vector2i(1, 1)
	var visible_cell := Vector2i(10, 10)
	layer.values[hidden_cell] = 100
	layer.values[visible_cell] = 100
	var near_refinery := FakeRefinery.new()
	near_refinery.position = Vector3(2.0, 0.0, 0.0)
	near_refinery.owner_player_id = player.player_id
	near_refinery.add_to_group("buildings")
	root.add_child(near_refinery)
	var manual_refinery := FakeRefinery.new()
	manual_refinery.position = Vector3(30.0, 0.0, 0.0)
	manual_refinery.owner_player_id = player.player_id
	manual_refinery.add_to_group("buildings")
	root.add_child(manual_refinery)
	var harvester := TestHarvester.new()
	harvester.owner_player_id = player.player_id
	harvester.max_spice = 100.0
	harvester.spice = 50.0
	root.add_child(harvester)

	_expect(harvester.command_unload(manual_refinery, grid, layer), "manual unloading with map context must enable the continuing cycle")
	harvester._harvester.cancel_unload_order()
	harvester._harvester.set_auto_spice_cell_filter(func(cell: Vector2i) -> bool: return cell != hidden_cell)
	harvester._harvester.advance_harvest_cycle()
	_expect(harvester._harvester.harvest_target_cell() == visible_cell, "automatic field selection must skip cells rejected by the future visibility predicate")

	harvester._harvester.cancel_harvest_order()
	harvester.spice = harvester.max_spice
	harvester._harvester.advance_harvest_cycle()
	_expect(harvester._harvester.assigned_refinery() == manual_refinery, "the manually selected refinery must remain bound even when another owned refinery is closer")
	_expect(harvester.command_unload(near_refinery, grid, layer), "a later manual unload must be able to redirect the active trip")
	_expect(harvester._harvester.assigned_refinery() == near_refinery, "manual redirection must replace the persistent refinery binding")
	var manual_move := Vector3(40.0, 0.0, 40.0)
	harvester.move_to(manual_move)
	harvester._harvester.advance_harvest_cycle()
	_expect(not harvester._harvester.has_harvest_order() and not harvester._harvester.has_unload_order(), "an ordinary manual move must stop automatic cycling until a new harvest or unload command")

	harvester.queue_free()
	near_refinery.queue_free()
	manual_refinery.queue_free()
	return token


func _test_full_unload(token: int, player: PlayerData) -> int:
	player.money = 0
	var grid := FakeGrid.new()
	var refinery := FakeRefinery.new()
	root.add_child(refinery)
	var harvester := TestHarvester.new()
	harvester.owner_player_id = player.player_id
	harvester.max_spice = 700.0
	harvester.spice = 700.0
	harvester._harvester.unload_rate_per_update = 2.0
	root.add_child(harvester)
	_park_for_unload(harvester, refinery, grid)
	_expect(harvester.animation_log.back() == HarvesterControllerScript.UNLOAD_START_ANIMATION, "parking must start Harv_Unload_Start")
	harvester._harvester.advance_unload_order(0.1)
	_expect(harvester.animation_log.back() == HarvesterControllerScript.UNLOAD_HOLD_ANIMATION, "UnloadStart must be followed by UnloadHold")
	for cycle in 35:
		harvester._harvester.advance_unload_order(0.5)
	_expect(is_zero_approx(harvester.spice), "35 half-second hold cycles must empty the 700-credit bunker")
	_expect(player.money == 700, "every removed cargo credit must be added to the owning player")
	_expect(harvester.animation_log.back() == HarvesterControllerScript.UNLOAD_END_ANIMATION, "an empty bunker must enter Harv_Unload_End")
	harvester._harvester.advance_unload_order(0.1)
	_expect(refinery.release_delays == [3.0], "UnloadEnd completion must release the pad with a three-second delay")
	_expect(harvester._harvester.unload_phase() == HarvesterControllerScript.UnloadPhase.RETURN_FRONT, "normal completion must return the harvester to the refinery front")
	harvester.global_position = refinery.front
	harvester._harvester.advance_unload_order(0.0)
	_expect(not harvester._harvester.has_unload_order(), "arrival at the front must complete the unloading order")

	harvester.queue_free()
	refinery.queue_free()
	return token


func _test_unload_waits_for_dock(token: int, player: PlayerData) -> int:
	var grid := FakeGrid.new()
	var refinery := FakeRefinery.new()
	refinery.available = false
	refinery.position = Vector3(10.0, 0.0, 10.0)
	refinery.front = Vector3(4.0, 0.0, 10.0)
	root.add_child(refinery)
	var harvester := TestHarvester.new()
	harvester.owner_player_id = player.player_id
	harvester.max_spice = 700.0
	harvester.spice = 100.0
	root.add_child(harvester)
	harvester.global_position = refinery.front
	_expect(harvester.command_unload(refinery, grid), "an owned refinery must accept an unloading order")
	_expect(harvester.target_position == refinery.front, "with every dock occupied the waiting route must stay outside at the refinery front instead of targeting its centre")
	harvester._harvester.advance_unload_order(0.0)
	harvester._harvester.advance_unload_order(0.0)
	_expect(harvester._harvester.unload_phase() == HarvesterControllerScript.UnloadPhase.WAIT_DOCK, "an occupied refinery must leave the harvester waiting near the building")
	_expect(harvester._harvester.unload_dock() == -1 and refinery.reserved_by == null, "waiting must not claim an unavailable pad")
	refinery.available = true
	harvester._harvester.advance_unload_order(0.0)
	_expect(harvester._harvester.unload_phase() == HarvesterControllerScript.UnloadPhase.PARK, "a newly free pad must be reserved on the next update")
	_expect(harvester._harvester.unload_dock() == 0 and refinery.reserved_by == harvester, "the selected pad must be exclusively reserved")

	harvester._harvester.cancel_unload_order()
	harvester.queue_free()
	refinery.queue_free()
	return token


func _test_side_dock_routes_directly(token: int, player: PlayerData) -> int:
	var grid := FakeGrid.new()
	var navigation := FakeNavigation.new()
	var refinery := FakeMultiDockRefinery.new()
	refinery.owner_player_id = player.player_id
	var central_harvester := Node.new()
	refinery.reservations[0] = central_harvester
	root.add_child(refinery)
	var harvester := TestHarvester.new()
	harvester.owner_player_id = player.player_id
	harvester.max_spice = 700.0
	harvester.spice = 100.0
	root.add_child(harvester)
	harvester.global_position = Vector3(-20.0, 0.0, 2.0)
	harvester.set_navigation_managed(true)
	harvester.set_navigation_controller(navigation)

	_expect(harvester.command_unload(refinery, grid), "the second harvester must accept a multi-dock refinery order")
	_expect(harvester._harvester.unload_phase() == HarvesterControllerScript.UnloadPhase.PARK and harvester._harvester.unload_dock() == 1, "an occupied central dock must make the second harvester reserve the free side dock immediately")
	_expect(navigation.dock_targets == [refinery.dock_positions[1]], "the first route must target the reserved side dock directly")
	_expect(navigation.move_targets.is_empty(), "a free side dock must not insert a generic approach through the refinery center")

	harvester._harvester.cancel_unload_order()
	harvester.queue_free()
	refinery.queue_free()
	central_harvester.free()
	return token


func _test_unload_navigation_arrival(token: int, player: PlayerData) -> int:
	var grid := FakeGrid.new()
	var layer := FakeSpiceLayer.new()
	var field := Vector2i(50, 50)
	layer.values[field] = 100
	var navigation := FakeNavigation.new()
	var refinery := FakeRefinery.new()
	refinery.position = Vector3(10.0, 0.0, 4.0)
	refinery.front = Vector3(30.0, 0.0, 20.0)
	root.add_child(refinery)
	var harvester := TestHarvester.new()
	harvester.owner_player_id = player.player_id
	harvester.max_spice = 700.0
	harvester.spice = 100.0
	root.add_child(harvester)
	harvester.set_navigation_managed(true)
	harvester.set_navigation_controller(navigation)

	_expect(harvester.command_unload(refinery, grid, layer), "the managed harvester must accept the unloading order")
	_expect(
		harvester._harvester.unload_phase() == HarvesterControllerScript.UnloadPhase.PARK \
		and harvester.target_position.is_equal_approx(refinery.dock),
		"an available dock must be reserved and targeted before any generic refinery approach"
	)
	harvester.global_position = refinery.dock + Vector3(0.0, 0.0, 0.45)
	harvester.face_direction(refinery.refinery_dock_facing_direction(0))
	harvester._harvester.advance_unload_order(0.0)
	_expect(harvester._harvester.unload_phase() == HarvesterControllerScript.UnloadPhase.START, "parking must use the shared navigation arrival distance too")
	_expect(navigation.is_held(harvester), "a harvester parked on a refinery pad must hold position throughout unloading")
	harvester.spice = 0.0
	harvester._harvester.advance_unload_order(0.1)
	harvester._harvester.advance_unload_order(0.5)
	harvester._harvester.advance_unload_order(0.1)
	_expect(not navigation.is_held(harvester), "UnloadEnd completion must release the navigation hold for the exit route")
	_expect(not harvester._harvester.has_unload_order() and harvester._harvester.has_harvest_order(), "normal managed unloading must hand off directly to the next harvest order")
	_expect(navigation.departure_targets.back() == grid.grid_to_world(field), "the direct field route must retain temporary dock-cell access without becoming an exact dock order")

	harvester.queue_free()
	refinery.queue_free()
	return token


func _test_refinery_rally_selects_next_field(token: int, player: PlayerData) -> int:
	var grid := FakeGrid.new()
	var layer := FakeSpiceLayer.new()
	var near_dock := Vector2i(3, 0)
	var near_rally := Vector2i(50, 0)
	layer.values[near_dock] = 100
	layer.values[near_rally] = 100
	var refinery := FakeRefinery.new()
	refinery.owner_player_id = player.player_id
	refinery.dock = Vector3(2.0, 0.0, 0.0)
	refinery.rally_point = Vector3(50.0, 0.0, 0.0)
	root.add_child(refinery)
	var harvester := TestHarvester.new()
	harvester.owner_player_id = player.player_id
	harvester.max_spice = 100.0
	harvester.spice = 1.0
	root.add_child(harvester)

	_park_for_unload(harvester, refinery, grid, layer)
	harvester.spice = 0.0
	harvester._harvester.advance_unload_order(0.1)
	harvester._harvester.advance_unload_order(0.5)
	harvester._harvester.advance_unload_order(0.1)

	_expect(
		harvester._harvester.harvest_target_cell() == near_rally,
		"after unloading, the refinery rally point must be the origin of the nearest-spice search"
	)
	_expect(
		not harvester.move_targets.has(refinery.rally_point),
		"the refinery rally point must not become an intermediate harvester destination"
	)

	harvester.queue_free()
	refinery.queue_free()
	return token


func _test_unload_parking_turn_rate(token: int, player: PlayerData) -> int:
	var grid := FakeGrid.new()
	var refinery := FakeRefinery.new()
	root.add_child(refinery)
	var harvester := TestHarvester.new()
	harvester.owner_player_id = player.player_id
	harvester.max_spice = 700.0
	harvester.spice = 100.0
	harvester.turn_rate = 0.1
	root.add_child(harvester)
	harvester.global_position = refinery.front
	harvester.command_unload(refinery, grid)
	harvester._harvester.advance_unload_order(0.0)
	harvester._harvester.advance_unload_order(0.0)
	harvester.global_position = refinery.dock

	harvester._harvester.advance_unload_order(0.25)
	_expect(
		harvester._harvester.unload_phase() == HarvesterControllerScript.UnloadPhase.PARK \
		and harvester.animation_log.is_empty(),
		"parking must wait for the required dock heading before unloading"
	)
	_expect(
		is_equal_approx(absf(harvester.global_rotation.y), 0.5),
		"a 0.1-radian TurnRate must rotate by 0.5 radians over five movement updates"
	)
	harvester._harvester.advance_unload_order(1.0)
	_expect(
		harvester._harvester.unload_phase() == HarvesterControllerScript.UnloadPhase.PARK,
		"parking must keep turning while the dock heading has not been reached"
	)
	harvester._harvester.advance_unload_order(0.5)
	_expect(
		harvester._harvester.unload_phase() != HarvesterControllerScript.UnloadPhase.PARK \
		and harvester.animation_log.has(HarvesterControllerScript.UNLOAD_START_ANIMATION),
		"unloading may start after the turn-rate-limited rotation reaches the dock heading"
	)

	harvester.queue_free()
	refinery.queue_free()
	return token


func _test_unload_interruption(token: int, player: PlayerData) -> int:
	var grid := FakeGrid.new()
	var start_refinery := FakeRefinery.new()
	root.add_child(start_refinery)
	var start_harvester := TestHarvester.new()
	start_harvester.owner_player_id = player.player_id
	start_harvester.max_spice = 700.0
	start_harvester.spice = 100.0
	root.add_child(start_harvester)
	_park_for_unload(start_harvester, start_refinery, grid)
	var start_move := Vector3(10.0, 0.0, 0.0)
	start_harvester.move_to(start_move)
	_expect(start_harvester.target_position != start_move, "a direct order during UnloadStart must wait")
	start_harvester._harvester.advance_unload_order(0.1)
	_expect(start_harvester.animation_log == [
		HarvesterControllerScript.UNLOAD_START_ANIMATION,
		HarvesterControllerScript.UNLOAD_END_ANIMATION,
	], "interrupting UnloadStart must skip UnloadHold and play UnloadEnd")
	start_harvester._harvester.advance_unload_order(0.1)
	_expect(start_harvester.target_position == start_move, "the pending move may start only after UnloadEnd finishes")
	_expect(is_equal_approx(start_harvester.spice, 100.0), "UnloadStart interruption must transfer no cargo")

	player.money = 0
	var hold_refinery := FakeRefinery.new()
	root.add_child(hold_refinery)
	var hold_harvester := TestHarvester.new()
	hold_harvester.owner_player_id = player.player_id
	hold_harvester.max_spice = 700.0
	hold_harvester.spice = 100.0
	hold_harvester._harvester.unload_rate_per_update = 2.0
	root.add_child(hold_harvester)
	_park_for_unload(hold_harvester, hold_refinery, grid)
	hold_harvester._harvester.advance_unload_order(0.1)
	hold_harvester._harvester.advance_unload_order(0.25)
	_expect(player.money == 10 and is_equal_approx(hold_harvester.spice, 90.0), "UnloadHold must transfer at 40 credits per second")
	var hold_move := Vector3(12.0, 0.0, 0.0)
	_expect(not hold_harvester.prepare_navigation_order(hold_move), "the unit navigation API must defer a move during UnloadHold")
	hold_harvester._harvester.advance_unload_order(0.25)
	_expect(player.money == 10 and is_equal_approx(hold_harvester.spice, 90.0), "cargo transfer must stop immediately after an interrupt")
	_expect(hold_harvester.animation_log.back() == HarvesterControllerScript.UNLOAD_END_ANIMATION, "the interrupted hold cycle must finish before UnloadEnd")
	hold_harvester._harvester.advance_unload_order(0.1)
	_expect(hold_harvester.target_position == hold_move, "the hold interruption's pending move must start after UnloadEnd")

	start_harvester.queue_free()
	start_refinery.queue_free()
	hold_harvester.queue_free()
	hold_refinery.queue_free()
	return token


func _test_unload_refinery_capture(token: int, player: PlayerData) -> int:
	player.money = 0
	var grid := FakeGrid.new()
	var refinery := FakeRefinery.new()
	root.add_child(refinery)
	var harvester := TestHarvester.new()
	harvester.owner_player_id = player.player_id
	harvester.max_spice = 700.0
	harvester.spice = 100.0
	harvester._harvester.unload_rate_per_update = 2.0
	root.add_child(harvester)
	_park_for_unload(harvester, refinery, grid)
	harvester._harvester.advance_unload_order(0.1)
	harvester._harvester.advance_unload_order(0.25)
	_expect(player.money == 10, "UnloadHold must transfer cargo before the refinery is captured")

	refinery.owner_player_id = player.player_id + 1
	harvester._harvester.advance_unload_order(0.25)
	_expect(player.money == 10 and is_equal_approx(harvester.spice, 90.0), "capture must stop cargo transfer immediately")
	_expect(harvester.animation_log.back() == HarvesterControllerScript.UNLOAD_END_ANIMATION, "capture during UnloadHold must finish the current clip and play UnloadEnd")
	harvester._harvester.advance_unload_order(0.1)
	_expect(not harvester._harvester.has_unload_order(), "captured refinery must not receive a return-to-front movement")
	_expect(refinery.release_delays == [3.0], "capture must still release the occupied pad after UnloadEnd")

	harvester.queue_free()
	refinery.queue_free()
	return token


func _park_for_unload(
		harvester: TestHarvester,
		refinery: FakeRefinery,
		grid: FakeGrid,
		spice_layer = null
	) -> void:
	harvester.global_position = refinery.front
	harvester.command_unload(refinery, grid, spice_layer)
	harvester._harvester.advance_unload_order(0.0)
	harvester._harvester.advance_unload_order(0.0)
	harvester.global_position = refinery.dock
	harvester.face_direction(refinery.refinery_dock_facing_direction(0))
	harvester._harvester.advance_unload_order(0.0)


func _expect(condition: bool, message: String) -> void:
	_assertions += 1
	if condition:
		return
	_failures += 1
	printerr("FAIL: %s: %s" % [_current_case, message])


func _make_open_navigation_grid() -> MapNavigationGrid:
	var total := MapNavigationGrid.NAV_SIZE * MapNavigationGrid.NAV_SIZE
	var cpf := PackedInt32Array()
	var terrain := PackedInt32Array()
	var source_x := PackedInt32Array()
	var source_y := PackedInt32Array()
	var spice_values := PackedByteArray()
	var pass_mask := PackedInt32Array()
	var movement_cost := PackedFloat32Array()
	var buildable := PackedByteArray()
	for array in [cpf, terrain, source_x, source_y, spice_values, pass_mask, movement_cost, buildable]:
		array.resize(total)
	terrain.fill(MapNavigationGrid.TERRAIN_SAND)
	pass_mask.fill(MapNavigationGrid.PASS_GROUND | MapNavigationGrid.PASS_AIR)
	movement_cost.fill(1.0)
	var grid := MapNavigationGrid.new()
	grid.load_generated(
		"harvester-crowd-test", AABB(Vector3.ZERO, Vector3(256.0, 1.0, 256.0)), 1.0,
		cpf, terrain, source_x, source_y, spice_values, pass_mask, movement_cost, buildable, {}, {}
	)
	return grid
