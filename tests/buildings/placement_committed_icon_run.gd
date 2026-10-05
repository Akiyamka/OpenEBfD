extends SceneTree

const BuildingControllerScript := preload("res://scripts/buildings/building_controller.gd")
const BuildingPlacementScript := preload("res://scripts/buildings/building_placement.gd")
const BuildingOptionStateScript := preload("res://scripts/buildings/building_option_state.gd")
const PlacementContextScript := preload("res://scripts/buildings/placement_context.gd")
const ProductionSystemScript := preload("res://scripts/production/production_system.gd")
const CommandPumpScript := preload("res://tests/match/support/command_pump.gd")

var _assertions := 0
var _failures := 0
var _current_case := ""
var _completion_token := 5000


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
	var owner_player_id := 1
	var deployed := false

	func simulation_position() -> Vector3:
		return position

	func is_deployed() -> bool:
		return deployed


func _initialize() -> void:
	await process_frame
	var players = root.get_node("Players")
	players.reset_for_match()
	players.create_player(1, "Placement Icon Tester", Color.BLUE, &"Atreides", [], 1, 100, 7)
	players.local_player_id = 1

	_run_case("a submitted placement changes the ready icon to placing", _test_window_opens_visibly)
	_run_case("an immobile-unit refusal restores the ready icon", _test_refusal_closes_window)
	_run_case("starting placement again while committed changes nothing", _test_begin_while_committed)
	_run_case("a right intent while committed reaches neither bus nor order", _test_right_intent_while_committed)
	_run_case("a left intent while committed reaches neither bus nor order", _test_left_intent_while_committed)

	players.reset_for_match()
	if _failures > 0:
		printerr("Placement committed icon tests: %d failures after %d assertions" % [_failures, _assertions])
		quit(1)
		return
	print("Placement committed icon tests: %d assertions passed" % _assertions)
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


func _latest_state(states: Array, building_id: StringName):
	for index in range(states.size() - 1, -1, -1):
		if states[index].building_id == building_id:
			return states[index]
	return null


func _new_deployed_unit(cell: Vector2i) -> UnitStub:
	var unit := UnitStub.new()
	unit.deployed = true
	unit.position = Vector3(float(cell.x) + 0.5, 0.0, float(cell.y) + 0.5)
	unit.add_to_group("sim_units")
	unit.add_to_group("units")
	root.add_child(unit)
	return unit


func _test_window_opens_visibly(token: int) -> int:
	var fixture := _new_ready_controller(Vector2i(6, 4))
	var states: Array = []
	fixture[0].building_option_state_changed.connect(func(state) -> void: states.append(state))
	fixture[0]._try_place_ready_building(Vector2.ZERO)
	var state = _latest_state(states, &"ATWall")
	_expect(
		state != null
		and state.state == BuildingOptionStateScript.State.PLACING
		and state.status_text == "BUILDING",
		"the submitted order must emit the placing icon state and BUILDING caption"
	)
	_free_controller_fixture(fixture)
	return token


func _test_refusal_closes_window(token: int) -> int:
	var fixture := _new_ready_controller(Vector2i(6, 4))
	var states: Array = []
	fixture[0].building_option_state_changed.connect(func(state) -> void: states.append(state))
	fixture[0]._try_place_ready_building(Vector2.ZERO)
	var unit := _new_deployed_unit(Vector2i(6, 4))
	fixture[2].pump()
	var state = _latest_state(states, &"ATWall")
	_expect(
		state != null
		and state.state == BuildingOptionStateScript.State.READY
		and state.status_text == "PLACE",
		"an authority refusal must refresh the icon back to the active ready placement"
	)
	_expect(
		state == null or state.state != BuildingOptionStateScript.State.PLACING,
		"an authority refusal must not leave the icon in placing state"
	)
	unit.free()
	_free_controller_fixture(fixture)
	return token


func _test_begin_while_committed(token: int) -> int:
	var fixture := _new_ready_controller(Vector2i(6, 4))
	fixture[0]._building_placement.set_rotation_quarter_turns(1)
	fixture[0]._try_place_ready_building(Vector2.ZERO)
	var statuses: Array[String] = []
	fixture[0].status_changed.connect(func(status: String) -> void: statuses.append(status))
	fixture[0]._begin_ready_building_placement()
	_expect(statuses.is_empty(), "the committed path must not announce placement ready again")
	_expect(
		fixture[0]._committed_placement_cell == Vector2i(6, 4),
		"the committed cell must remain unchanged when placement is started again"
	)
	_expect(
		fixture[0]._building_placement.rotation_quarter_turns() == 1,
		"the committed placement rotation must not reset"
	)
	_free_controller_fixture(fixture)
	return token


func _test_right_intent_while_committed(token: int) -> int:
	var fixture := _new_ready_controller(Vector2i(6, 4))
	fixture[0]._try_place_ready_building(Vector2.ZERO)
	var pending_count: int = fixture[2].bus().pending_count()
	fixture[0].handle_building_intent(&"ATWall", MOUSE_BUTTON_RIGHT)
	_expect(fixture[2].bus().pending_count() == pending_count, "right intent must not submit a command")
	_expect(
		fixture[0]._building_queue.current_order() != null and fixture[0]._building_queue.current_order().ready,
		"right intent must not cancel or refund the ready order"
	)
	_free_controller_fixture(fixture)
	return token


func _test_left_intent_while_committed(token: int) -> int:
	var fixture := _new_ready_controller(Vector2i(6, 4))
	fixture[0]._try_place_ready_building(Vector2.ZERO)
	var pending_count: int = fixture[2].bus().pending_count()
	fixture[0].handle_building_intent(&"ATWall", MOUSE_BUTTON_LEFT)
	_expect(fixture[2].bus().pending_count() == pending_count, "left intent must not submit a command")
	_expect(
		fixture[0]._building_queue.current_order() != null and fixture[0]._building_queue.current_order().ready,
		"left intent must not enqueue a second order"
	)
	_free_controller_fixture(fixture)
	return token
