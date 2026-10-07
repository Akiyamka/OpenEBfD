extends SceneTree

const BuildingControllerScript := preload("res://scripts/buildings/building_controller.gd")
const BuildingPlacementScript := preload("res://scripts/buildings/building_placement.gd")
const BuildingOptionStateScript := preload("res://scripts/buildings/building_option_state.gd")
const OccupyGridScript := preload("res://scripts/buildings/occupy_grid.gd")
const PlacementContextScript := preload("res://scripts/buildings/placement_context.gd")
const ProductionSystemScript := preload("res://scripts/production/production_system.gd")
const CommandPumpScript := preload("res://tests/match/support/command_pump.gd")
const MatchFixtureScene := preload("res://tests/fixtures/match_fixture.tscn")
const SimPlaceBuildingCommandScript := preload("res://scripts/sim/commands/place_building_command.gd")
const SimMoveCommandScript := preload("res://scripts/sim/commands/move_command.gd")
const MapNavigationGridScript := preload("res://scripts/world/map/map_navigation_grid.gd")

var _assertions := 0
var _failures := 0
var _current_case := ""

const WALL_OCCUPY_ROWS: Array[String] = ["b"]
const BARRACKS_OCCUPY_ROWS: Array[String] = [
	"bbbbb", "bbbbb", "nbbbn", "nbbbn", "sssss", "sssss", "sssss",
]


class FakeGrid extends RefCounted:
	func is_loaded() -> bool:
		return true

	func grid_to_world(cell: Vector2i, centered: bool) -> Vector3:
		var offset := 0.5 if centered else 0.0
		return Vector3(float(cell.x) + offset, 0.0, float(cell.y) + offset)

	func cell_debug(_cell: Vector2i) -> Dictionary:
		return {"valid": true, "buildable": true}


class UnitStub extends Node3D:
	var owner_player_id := 2
	var deployed := true

	func simulation_position() -> Vector3:
		return position

	func is_deployed() -> bool:
		return deployed

	func sim_tick() -> void:
		pass

	func sim_tick_combat() -> void:
		pass


class HoverCellPlacement extends BuildingPlacement:
	var stub_cell: Variant = null

	func hover_cell_from_pointer(_pointer_position: Vector2):
		return stub_cell


func _initialize() -> void:
	await process_frame
	var players = root.get_node("Players")
	players.reset_for_match()
	players.create_player(1, "Pending Tester", Color.BLUE, &"Atreides", [], 1, 100, 7)
	players.create_player(2, "Pending Enemy", Color.RED, &"Harkonnen", [], 1, 100, 7)
	players.local_player_id = 1

	_run_case("a blocked placement defers its refusal", _test_blocked_placement_defers)
	_run_case("a terrain refusal remains immediate", _test_terrain_refusal_is_immediate)
	_run_case("a stale order opens no pending entry", _test_stale_order)
	_run_case("a cleared site places on the retry tick", _test_clear_site_places)
	_run_case("the deadline gives up only after the pending window", _test_deadline)
	_run_case("reservations exist only while an entry is pending", _test_reservation_lifetime)
	_run_case("the local placement icon stays committed while pending", _test_pending_icon)
	_run_case("pending retries preserve insertion order", _test_insertion_order)
	await _test_match_tick_and_reservation()

	players.reset_for_match()
	if _failures > 0:
		printerr("Pending placement tests: %d failures after %d assertions" % [_failures, _assertions])
		quit(1)
		return
	print("Pending placement tests: %d assertions passed" % _assertions)
	quit(0)


func _run_case(case_name: String, test: Callable) -> void:
	_current_case = case_name
	var failures_before := _failures
	test.call()
	if _failures == failures_before:
		print("PASS: %s" % case_name)


func _expect(condition: bool, message: String) -> void:
	_assertions += 1
	if condition:
		return
	_failures += 1
	printerr("FAIL: %s: %s" % [_current_case, message])


func _expect_case(case_name: String, condition: bool, message: String) -> void:
	_current_case = case_name
	_expect(condition, message)


func _new_fixture(cell: Vector2i) -> Array:
	var buildings_root := Node3D.new()
	root.add_child(buildings_root)
	var controller = BuildingControllerScript.new()
	root.add_child(controller)
	var placement := HoverCellPlacement.new()
	placement.stub_cell = cell
	controller._building_placement.free()
	controller._building_placement = placement
	var production = ProductionSystemScript.new()
	production.configure(root.get_node("Players"), Callable(controller, "_is_building_available_for_player"))
	var building_ids: Array[StringName] = [&"ATWall"]
	controller.setup(null, null, null, building_ids, production, null, null, null, null, null, null, Callable())
	var context := PlacementContextScript.new()
	context.navigation_grid = FakeGrid.new()
	context.buildings_root = buildings_root
	# The retry must see a building placed earlier in the same tick.  These are
	# the production callbacks, not test-owned occupancy bookkeeping.
	context.existing_building_occupy_rows = Callable(controller, "_occupy_rows_for_existing_building")
	context.existing_building_is_wall = Callable(controller, "_is_wall_building")
	controller._building_placement.setup(context)
	var pump := CommandPumpScript.new()
	pump.configure_queue_controllers(controller)
	controller._turn_scheduler = pump.turn_scheduler()
	controller._submit_tick_provider = Callable(pump, "next_orderable_tick")
	controller._building_queue.start(&"ATWall", "Wall", 0, 1)
	controller._building_queue.advance_tick(0)
	return [controller, buildings_root, pump, cell]


func _free_fixture(fixture: Array) -> void:
	fixture[0].free()
	fixture[1].free()


func _new_blocker(cell: Vector2i) -> UnitStub:
	var unit := UnitStub.new()
	unit.position = Vector3(float(cell.x) + 0.5, 0.0, float(cell.y) + 0.5)
	unit.add_to_group("sim_units")
	root.add_child(unit)
	return unit


func _reserved_cells_for(hover_cell: Vector2i, rows: Array[String]) -> Array[Vector2i]:
	var size := OccupyGridScript.size(rows)
	var hover_occupy := OccupyGridScript.nav_cell_to_occupy_cell(hover_cell, 2)
	var anchor := OccupyGridScript.occupy_cell_to_nav_cell(
		hover_occupy - Vector2i(size.x / 2, size.y / 2), 2
	)
	return OccupyGridScript.nav_cells(anchor, rows, 2)


func _contains_all(cells: Array[Vector2i], expected: Array[Vector2i]) -> bool:
	for cell in expected:
		if not cells.has(cell):
			return false
	return true


func _submit_blocked(fixture: Array, _unit: UnitStub) -> Array[String]:
	var statuses: Array[String] = []
	fixture[0].status_changed.connect(func(status: String) -> void: statuses.append(status))
	var command := SimPlaceBuildingCommandScript.new()
	command.player_id = 1
	command.building_id = &"ATWall"
	command.nav_cell = fixture[3]
	fixture[0].execute_place_building_command(command)
	return statuses


func _test_blocked_placement_defers() -> void:
	var fixture := _new_fixture(Vector2i(6, 4))
	var unit := _new_blocker(fixture[3])
	var statuses := _submit_blocked(fixture, unit)
	_expect(fixture[1].get_child_count() == 0, "the execution tick must not spawn over the blocker")
	_expect(fixture[0]._building_queue.current_order().ready, "the pending order must remain ready")
	_expect(not statuses.has("Wall cannot be placed there"), "the refusal must not be emitted on the execution tick")
	unit.free()
	_free_fixture(fixture)


func _test_terrain_refusal_is_immediate() -> void:
	var fixture := _new_fixture(Vector2i(6, 4))
	fixture[0]._building_placement._navigation_grid = null
	var statuses := _submit_blocked(fixture, null)
	_expect(statuses.has("Wall placement needs terrain"), "terrain remains an immediate existing verdict")
	_expect(not fixture[0]._pending_placement.has_entry(1), "terrain must not open a pending entry")
	_free_fixture(fixture)


func _test_stale_order() -> void:
	var fixture := _new_fixture(Vector2i(6, 4))
	var command := SimPlaceBuildingCommandScript.new()
	command.player_id = 1
	command.building_id = &"HBWall"
	command.nav_cell = fixture[3]
	fixture[0].execute_place_building_command(command)
	_expect(not fixture[0]._pending_placement.has_entry(1), "a stale command must remain discarded")
	_free_fixture(fixture)


func _test_clear_site_places() -> void:
	var fixture := _new_fixture(Vector2i(6, 4))
	var unit := _new_blocker(fixture[3])
	var statuses := _submit_blocked(fixture, unit)
	for _tick in 39:
		fixture[0].advance_tick()
	unit.position = Vector3(-20.0, 0.0, -20.0)
	# Tick 40 is the in-window retry named by the approved acceptance case.
	fixture[0].advance_tick()
	_expect(fixture[1].get_child_count() > 0, "the first clear retry must place the building")
	_expect(fixture[0]._building_queue.current_order() == null, "a successful retry consumes the ready order")
	_expect(statuses.has("Wall placed"), "a successful retry retains the existing placed status")
	unit.free()
	_free_fixture(fixture)


func _test_deadline() -> void:
	var fixture := _new_fixture(Vector2i(6, 4))
	var unit := _new_blocker(fixture[3])
	var statuses := _submit_blocked(fixture, unit)
	for _tick in 123:
		fixture[0].advance_tick()
	_expect(not statuses.has("Wall cannot be placed there"), "the deadline must not expire before tick 123")
	for _tick in 4:
		fixture[0].advance_tick()
	_expect(statuses.has("Wall cannot be placed there"), "the existing refusal arrives after the deadline")
	_expect(fixture[1].get_child_count() == 0, "a blocked deadline must not spawn a building")
	_expect(fixture[0]._building_queue.current_order().ready, "deadline expiry leaves the order ready")
	unit.free()
	_free_fixture(fixture)


func _test_reservation_lifetime() -> void:
	var fixture := _new_fixture(Vector2i(6, 4))
	var unit := _new_blocker(fixture[3])
	_submit_blocked(fixture, unit)
	for _tick in 40:
		fixture[0].advance_tick()
	var expected := _reserved_cells_for(fixture[3], WALL_OCCUPY_ROWS)
	var offered: Array[Vector2i] = fixture[0].pending_placement_reserved_nav_cells()
	_expect(offered.size() == expected.size() and _contains_all(offered, expected), "the provider must offer every cell of the pending footprint")
	for _tick in 87:
		fixture[0].advance_tick()
	_expect(fixture[0].pending_placement_reserved_nav_cells().is_empty(), "the reservation must leave with the resolved entry")
	unit.free()
	_free_fixture(fixture)


func _test_pending_icon() -> void:
	var fixture := _new_fixture(Vector2i(6, 4))
	var states: Array = []
	fixture[0].building_option_state_changed.connect(func(state) -> void: states.append(state))
	fixture[0]._begin_ready_building_placement()
	var unit := _new_blocker(fixture[3])
	fixture[0]._try_place_ready_building(Vector2.ZERO)
	fixture[2].pump()
	for _tick in 40:
		fixture[0].advance_tick()
	var state = states.back() if not states.is_empty() else null
	_expect(
		state != null and state.state == BuildingOptionStateScript.State.PLACING and state.status_text == "BUILDING",
		"pending retains the PLACING / BUILDING state through tick 40"
	)
	for _tick in 87:
		fixture[0].advance_tick()
	state = states.back() if not states.is_empty() else null
	_expect(state != null and state.state == BuildingOptionStateScript.State.READY, "the icon returns to READY after tick 127")
	# Keep the case's two assertions by folding the caption check above into
	# its pending-state assertion; the post-deadline state is the second one.
	unit.free()
	_free_fixture(fixture)


func _test_insertion_order() -> void:
	var fixture := _new_fixture(Vector2i(6, 4))
	var controller = fixture[0]
	var player_two_queue = controller.building_queue_for_player(2)
	player_two_queue.start(&"ATWall", "Wall", 0, 1)
	player_two_queue.advance_tick(0)
	var blocker := _new_blocker(fixture[3])
	var high := SimPlaceBuildingCommandScript.new()
	high.player_id = 2
	high.building_id = &"ATWall"
	high.nav_cell = fixture[3]
	controller.execute_place_building_command(high)
	# Different ticks are essential: same-tick command drain orders by player
	# id and would make a sorted retry indistinguishable from insertion order.
	controller.advance_tick()
	var low := SimPlaceBuildingCommandScript.new()
	low.player_id = 1
	low.building_id = &"ATWall"
	low.nav_cell = fixture[3]
	var statuses: Array[String] = []
	controller.status_changed.connect(func(status: String) -> void: statuses.append(status))
	controller.execute_place_building_command(low)
	for _tick in 39:
		controller.advance_tick()
	var lower_refused_before_clear := statuses.has("Wall cannot be placed there")
	blocker.position = Vector3(-20.0, 0.0, -20.0)
	controller.advance_tick()
	var winner = fixture[1].get_children().filter(
		func(child: Node) -> bool: return child is Node3D and child.get("owner_player_id") == 2
	)
	_expect(winner.size() == 1 and controller.building_queue_for_player(1).current_order().ready, "the higher player opened first must win the contested footprint")
	_expect(not lower_refused_before_clear and statuses.has("Wall cannot be placed there") and not controller._pending_placement.has_entry(1), "the lower player must refuse on the winner's placement tick, not at its deadline")
	blocker.free()
	_free_fixture(fixture)


func _test_match_tick_and_reservation() -> void:
	var match_instance = MatchFixtureScene.instantiate()
	root.add_child(match_instance)
	await process_frame
	await process_frame
	var controller = match_instance.get_node("BuildingController")
	var queue = controller.building_queue_for_player(1)
	queue.start(&"ATBarracks", "Barracks", 0, 1)
	queue.advance_tick(0)
	# This is an in-radius, buildable Barracks anchor on the fixed fixture map.
	# Group B deliberately uses only public Match/controller seams after setup.
	var cell := Vector2i(20, 20)
	var terrain = match_instance.get_node("Terrain")
	var unit := UnitStub.new()
	unit.position = terrain.navigation_grid.grid_to_world(cell, false)
	unit.add_to_group("sim_units")
	match_instance.get_node("Units").add_child(unit)
	var idle = match_instance.get_node("Units/NIABTank")
	idle.set_simulation_position(terrain.navigation_grid.grid_to_world(cell, true))
	var statuses: Array[String] = []
	controller.status_changed.connect(func(status: String) -> void: statuses.append(status))
	var command := SimPlaceBuildingCommandScript.new()
	command.player_id = 1
	command.building_id = &"ATBarracks"
	command.nav_cell = cell
	match_instance.command_bus().submit(command, match_instance.next_orderable_tick())
	match_instance.advance_ticks(40)
	var navigation = match_instance.get_node("UnitNavigationSystem")
	var map = navigation.runtime_map
	var reserved_cells := _reserved_cells_for(cell, BARRACKS_OCCUPY_ROWS)
	_expect_case("case 10: reservation is no-stop and passable", reserved_cells.all(func(reserved_cell: Vector2i) -> bool: return map.is_no_stop(reserved_cell)), "the refreshed map must mark every pending-footprint cell no-stop")
	_expect_case("case 10: reservation is no-stop and passable", reserved_cells.all(func(reserved_cell: Vector2i) -> bool: return map.is_passable(reserved_cell, MapNavigationGridScript.PASS_VEHICLE)), "every reservation cell must remain passable")
	var mover = match_instance.get_node("Units/ScoutA")
	var move := SimMoveCommandScript.new()
	move.player_id = 1
	move.entity_ids = PackedInt32Array([int(mover.get("entity_id"))])
	move.target = terrain.navigation_grid.grid_to_world(cell, true)
	match_instance.command_bus().submit(move, match_instance.next_orderable_tick())
	match_instance.advance_ticks(1)
	var first_destination: Vector2i = terrain.navigation_grid.world_to_grid(
		navigation.agent_debug(mover)["destination"]
	)
	_expect_case("case 11: reservation rejects then releases move parking", not reserved_cells.has(first_destination), "a move order must resolve outside the complete pending footprint")
	_expect_case("case 12: idle unit is swept from reservation", not reserved_cells.has(terrain.navigation_grid.world_to_grid(idle.simulation_position())), "an idle unit on the reservation must be swept outside its footprint")
	match_instance.advance_ticks(82)
	_expect_case("case 9: central tick drives countdown", not statuses.has("Barracks cannot be placed there"), "central ticking must preserve the pending window through tick 123")
	match_instance.advance_ticks(4)
	_expect_case("case 9: central tick drives countdown", statuses.has("Barracks cannot be placed there"), "central ticking must expire the pending command")
	# The pending entry resolves at tick 127. The overlay is rebuilt on the
	# established blocker cadence, so let its next normal refresh expose the
	# release before issuing the second order.
	match_instance.advance_ticks(13)
	var released_move := SimMoveCommandScript.new()
	released_move.player_id = 1
	released_move.entity_ids = PackedInt32Array([int(mover.get("entity_id"))])
	released_move.target = terrain.navigation_grid.grid_to_world(cell, true)
	match_instance.command_bus().submit(released_move, match_instance.next_orderable_tick())
	match_instance.advance_ticks(1)
	var released_destination: Vector2i = terrain.navigation_grid.world_to_grid(
		navigation.agent_debug(mover)["destination"]
	)
	_expect_case("case 11: reservation rejects then releases move parking", released_destination == cell, "a move order after tick 127 must resolve to the requested cell")
	match_instance.queue_free()
