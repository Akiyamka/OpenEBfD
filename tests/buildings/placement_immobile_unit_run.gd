extends SceneTree

const BuildingControllerScript := preload("res://scripts/buildings/building_controller.gd")
const BuildingPlacementScript := preload("res://scripts/buildings/building_placement.gd")
const PlacementContextScript := preload("res://scripts/buildings/placement_context.gd")
const ProductionSystemScript := preload("res://scripts/production/production_system.gd")
const CommandPumpScript := preload("res://tests/match/support/command_pump.gd")
const MatchFixtureScene := preload("res://tests/fixtures/match_fixture.tscn")
const SimPlaceBuildingCommandScript := preload("res://scripts/sim/commands/place_building_command.gd")

var _assertions := 0
var _failures := 0
var _current_case := ""
var _completion_token := 4000


class FakeGrid extends RefCounted:
	func is_loaded() -> bool:
		return true

	func grid_to_world(cell: Vector2i, centered: bool) -> Vector3:
		var offset := 0.5 if centered else 0.0
		return Vector3(float(cell.x) + offset, 0.0, float(cell.y) + offset)

	func cell_debug(_cell: Vector2i) -> Dictionary:
		return {"valid": true, "buildable": true}


class HoverCellPlacement extends BuildingPlacement:
	var stub_cell: Variant = null

	func hover_cell_from_pointer(_pointer_position: Vector2):
		return stub_cell


class UnitStub extends Node3D:
	var entity_id := 0
	var owner_player_id := 1
	var deployed := false

	func simulation_position() -> Vector3:
		return position

	func set_simulation_position(value: Vector3) -> void:
		position = value

	func is_deployed() -> bool:
		return deployed

	func sim_tick() -> void:
		pass

	func sim_tick_combat() -> void:
		pass

	func stop_at_current_position() -> void:
		pass


func _initialize() -> void:
	await process_frame
	var players = root.get_node("Players")
	players.reset_for_match()
	players.create_player(1, "Placement Tester", Color.BLUE, &"Atreides", [], 1, 100, 7)
	players.create_player(2, "Enemy Tester", Color.RED, &"Harkonnen", [], 1, 100, 7)
	players.local_player_id = 1

	_run_case("a friendly immobile unit suppresses the place click before the wire", _test_friendly_filter)
	_run_case("authority refuses another player's immobile unit", _test_authority_other_owner)
	_run_case("enemy immobile units pass the filter but fail at authority", _test_owner_asymmetry)
	_run_case("a bypassing caller still shoves a mobile unit aside", _test_mobile_unit_still_places)
	_run_case("the query uses the rotated footprint", _test_rotation)
	_run_case("a refusal leaves the order ready and placement uncommitted", _test_refusal_preserves_order)
	_run_case("the two footprint questions differ on a mobile unit", _test_mobile_unit_questions_differ)
	_run_case("neither footprint question fires outside the footprint", _test_unit_outside_footprint)
	_run_case("the any-unit footprint question respects its owner filter", _test_any_unit_owner_filter)
	_run_case("the query fails closed when no navigation grid is available", _test_missing_grid)
	_run_case("a queued-for-deletion unit does not block the authoritative query", _test_queued_unit_is_not_live)
	await _test_authority_other_owner_through_real_match()

	players.reset_for_match()
	if _failures > 0:
		printerr("Placement immobile unit tests: %d failures after %d assertions" % [_failures, _assertions])
		quit(1)
		return
	print("Placement immobile unit tests: %d assertions passed" % _assertions)
	quit(0)


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


func _expect(condition: bool, message: String) -> void:
	_assertions += 1
	if condition:
		return
	_failures += 1
	printerr("FAIL: %s: %s" % [_current_case, message])


func _new_unit(owner_id: int, deployed: bool, unit_position: Vector3) -> UnitStub:
	var unit := UnitStub.new()
	unit.owner_player_id = owner_id
	unit.deployed = deployed
	unit.position = unit_position
	unit.add_to_group("sim_units")
	unit.add_to_group("units")
	root.add_child(unit)
	return unit


func _new_ready_controller(cell: Vector2i) -> Array:
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
	context.existing_building_occupy_rows = Callable()
	controller._building_placement.setup(context)
	var pump := CommandPumpScript.new()
	pump.configure_queue_controllers(controller)
	controller._turn_scheduler = pump.turn_scheduler()
	controller._submit_tick_provider = Callable(pump, "next_orderable_tick")
	controller._building_queue.start(&"ATWall", "Wall", 0, 1)
	controller._building_queue.advance_tick(0)
	controller._begin_ready_building_placement()
	return [controller, buildings_root, pump]


func _free_controller_fixture(fixture: Array) -> void:
	fixture[0].free()
	fixture[1].free()


func _test_friendly_filter(token: int) -> int:
	var fixture := _new_ready_controller(Vector2i(6, 4))
	var unit := _new_unit(1, true, Vector3(6.5, 0.0, 4.5))
	fixture[0]._try_place_ready_building(Vector2.ZERO)
	_expect(fixture[2].bus().pending_count() == 0, "a friendly deployed unit must suppress the command before it reaches the bus")
	_expect(fixture[0]._building_queue.current_order() != null and fixture[0]._building_queue.current_order().ready, "the filtered order must remain ready")
	_expect(fixture[0]._committed_placement_cell == null, "the filtered click must not commit a placement cell")
	unit.free()
	_free_controller_fixture(fixture)
	return token


func _test_authority_other_owner(token: int) -> int:
	var fixture := _new_ready_controller(Vector2i(6, 4))
	var unit := _new_unit(2, true, Vector3(6.5, 0.0, 4.5))
	fixture[0]._try_place_ready_building(Vector2.ZERO)
	_expect(fixture[2].bus().pending_count() == 1, "setup: enemy units must not suppress a local click")
	fixture[2].pump()
	_expect(fixture[1].get_child_count() == 0, "authority must not spawn over another player's deployed unit")
	_expect(fixture[0]._building_queue.current_order() != null and fixture[0]._building_queue.current_order().ready, "authority refusal must leave the order ready")
	unit.free()
	_free_controller_fixture(fixture)
	return token


func _test_owner_asymmetry(token: int) -> int:
	var fixture := _new_ready_controller(Vector2i(6, 4))
	var unit := _new_unit(2, true, Vector3(6.5, 0.0, 4.5))
	fixture[0]._try_place_ready_building(Vector2.ZERO)
	_expect(fixture[2].bus().pending_count() == 1, "the friendly-only filter must submit past an enemy deployed unit")
	fixture[2].pump()
	_expect(fixture[1].get_child_count() == 0, "the owner-blind authority must refuse that submitted command")
	unit.free()
	_free_controller_fixture(fixture)
	return token


func _test_mobile_unit_still_places(token: int) -> int:
	var fixture := _new_ready_controller(Vector2i(6, 4))
	var unit := _new_unit(1, false, Vector3(6.5, 0.0, 4.5))
	var template := Node3D.new()
	var scene := PackedScene.new()
	var rows: Array[String] = ["b"]
	scene.pack(template)
	template.free()
	var result = fixture[0]._building_placement.place_without_preview(
		&"ATWall", "Wall", rows, true, 0, Vector2i(6, 4), scene, 1
	)
	_expect(result == BuildingPlacementScript.PlaceResult.PLACED and fixture[1].get_child_count() > 0, "a bypassing caller must still place the building")
	_expect(unit.simulation_position().x < 6.0 or unit.simulation_position().z < 4.0, "a bypassing caller must still shove a mobile unit out")
	unit.free()
	_free_controller_fixture(fixture)
	return token


func _test_rotation(token: int) -> int:
	var placement = BuildingPlacementScript.new()
	root.add_child(placement)
	var context := PlacementContextScript.new()
	context.navigation_grid = FakeGrid.new()
	placement.setup(context)
	var unit := _new_unit(1, true, Vector3(10.0, 0.0, 13.0))
	var rows: Array[String] = ["XXX", "X.."]
	_expect(not placement.has_immobile_unit_in_footprint(rows, 0, Vector2i(10, 10)), "setup: the unit must be outside the unrotated footprint")
	_expect(placement.has_immobile_unit_in_footprint(rows, 1, Vector2i(10, 10)), "rotation must use the rotated footprint box")
	unit.free()
	placement.free()
	return token


func _test_refusal_preserves_order(token: int) -> int:
	var fixture := _new_ready_controller(Vector2i(6, 4))
	var unit := _new_unit(1, true, Vector3(6.5, 0.0, 4.5))
	fixture[0]._try_place_ready_building(Vector2.ZERO)
	_expect(fixture[0]._building_queue.current_order() != null and fixture[0]._building_queue.current_order().ready, "a refusal must keep the order ready")
	_expect(fixture[0]._committed_placement_cell == null, "a refusal must leave no committed cell")
	unit.free()
	_free_controller_fixture(fixture)
	return token


func _test_mobile_unit_questions_differ(token: int) -> int:
	var placement = BuildingPlacementScript.new()
	root.add_child(placement)
	var context := PlacementContextScript.new()
	context.navigation_grid = FakeGrid.new()
	placement.setup(context)
	var unit := _new_unit(1, false, Vector3(6.5, 0.0, 4.5))
	_expect(placement.has_any_unit_in_footprint(["X"], 0, Vector2i(6, 4)), "any-unit query must see a mobile unit")
	_expect(not placement.has_immobile_unit_in_footprint(["X"], 0, Vector2i(6, 4)), "immobile-only query must skip a mobile unit")
	unit.free()
	placement.free()
	return token


func _test_unit_outside_footprint(token: int) -> int:
	var placement = BuildingPlacementScript.new()
	root.add_child(placement)
	var context := PlacementContextScript.new()
	context.navigation_grid = FakeGrid.new()
	placement.setup(context)
	var unit := _new_unit(1, false, Vector3(-200.0, 0.0, -200.0))
	_expect(not placement.has_any_unit_in_footprint(["X"], 0, Vector2i(6, 4)) and not placement.has_immobile_unit_in_footprint(["X"], 0, Vector2i(6, 4)), "neither footprint query must fire for a unit outside the footprint")
	unit.free()
	placement.free()
	return token


func _test_any_unit_owner_filter(token: int) -> int:
	var placement = BuildingPlacementScript.new()
	root.add_child(placement)
	var context := PlacementContextScript.new()
	context.navigation_grid = FakeGrid.new()
	placement.setup(context)
	var unit := _new_unit(2, false, Vector3(6.5, 0.0, 4.5))
	_expect(placement.has_any_unit_in_footprint(["X"], 0, Vector2i(6, 4), null), "an unfiltered any-unit query must see another owner's mobile unit")
	_expect(not placement.has_any_unit_in_footprint(["X"], 0, Vector2i(6, 4), 1), "an owner-filtered any-unit query must skip another owner's mobile unit")
	unit.free()
	placement.free()
	return token


func _test_missing_grid(token: int) -> int:
	var placement = BuildingPlacementScript.new()
	root.add_child(placement)
	var unit := _new_unit(1, true, Vector3.ZERO)
	_expect(not placement.has_immobile_unit_in_footprint(["X"], 0, Vector2i.ZERO), "a query without a usable grid must answer false")
	_expect(not placement.has_any_unit_in_footprint(["X"], 0, Vector2i.ZERO), "the any-unit query without a usable grid must answer false")
	unit.free()
	placement.free()
	return token


func _test_queued_unit_is_not_live(token: int) -> int:
	var placement = BuildingPlacementScript.new()
	root.add_child(placement)
	var context := PlacementContextScript.new()
	context.navigation_grid = FakeGrid.new()
	placement.setup(context)
	var unit := _new_unit(1, true, Vector3(6.5, 0.0, 4.5))
	unit.queue_free()
	_expect(not placement.has_immobile_unit_in_footprint(["X"], 0, Vector2i(6, 4)), "a queued-for-deletion unit must not block placement")
	_expect(not placement.has_any_unit_in_footprint(["X"], 0, Vector2i(6, 4)), "a queued-for-deletion unit must not block the any-unit query")
	placement.free()
	return token


func _test_authority_other_owner_through_real_match() -> void:
	var match_instance = MatchFixtureScene.instantiate()
	root.add_child(match_instance)
	await process_frame
	await process_frame
	var controller = match_instance.get_node("BuildingController")
	var queue = controller.building_queue_for_player(1)
	queue.start(&"ATBarracks", "Barracks", 0, 1)
	queue.advance_tick(0)
	var rows: Array[String] = controller._building_occupy_rows(controller._building_config(&"ATBarracks"))
	var cell = _first_available_barracks_cell(match_instance, controller, rows)
	_expect(cell != null, "setup: the real Match must provide an available Barracks cell")
	if cell == null:
		match_instance.queue_free()
		return
	var unit := UnitStub.new()
	unit.owner_player_id = 2
	unit.deployed = true
	unit.position = match_instance.terrain.navigation_grid.grid_to_world(cell, false)
	unit.add_to_group("sim_units")
	match_instance.get_node("Units").add_child(unit)
	_expect(controller._building_placement.has_immobile_unit_in_footprint(rows, 0, cell, null), "setup: the real Match sim_units population must contain the enemy deployed unit")
	var buildings_before := match_instance.get_node("Buildings").get_child_count()
	var command := SimPlaceBuildingCommandScript.new()
	command.player_id = 1
	command.building_id = &"ATBarracks"
	command.nav_cell = cell
	match_instance._command_bus.submit(command, match_instance.next_orderable_tick())
	match_instance.advance_ticks(1)
	_expect(queue.current_order() != null and queue.current_order().ready, "the real Match tick must leave an authority-refused order ready")
	_expect(match_instance.get_node("Buildings").get_child_count() == buildings_before, "an available real-Match command must not spawn over an enemy deployed unit")
	unit.queue_free()
	match_instance.queue_free()


func _first_available_barracks_cell(match_instance, controller, rows: Array[String]):
	var grid = match_instance.terrain.navigation_grid
	var center: Vector2i = grid.world_to_grid(match_instance.get_node("Buildings/ATConYard").global_position)
	for radius in range(2, 16):
		for x in range(-radius, radius + 1):
			for y in [-radius, radius]:
				var candidate := center + Vector2i(x, y)
				if controller._building_placement.evaluate_without_preview(&"ATBarracks", rows, false, 0, candidate, 1) == BuildingPlacementScript.PlaceResult.AVAILABLE:
					return candidate
	return null
