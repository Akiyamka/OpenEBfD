extends SceneTree

## Slice D6 binds availability catalogs to the real Match bus.  Player 1 is
## Atreides and player 2 is Ordos/Ix, so neither of player 2's candidate ids is
## part of the local sidebar roster.
const LegacyRulesFixture := preload("res://tests/support/legacy_rules_fixture.gd")
const MatchFixtureScene := preload("res://tests/fixtures/match_fixture.tscn")
const SimBuildOrderCommandScript := preload("res://scripts/sim/commands/build_order_command.gd")
const SimUpgradeOrderCommandScript := preload("res://scripts/sim/commands/upgrade_order_command.gd")
const ORConYardScene := preload("res://assets/converted/buildings/ORConYard/ORConYard.scn")
const ORSmWindtrapScene := preload("res://assets/converted/buildings/ORSmWindtrap/ORSmWindtrap.scn")
const ORFactoryScene := preload("res://assets/converted/buildings/ORFactory/ORFactory.scn")
const IXResCentreScene := preload("res://scenes/buildings/ix_res_centre.tscn")

var _assertions := 0
var _failures := 0
var _current_case := ""


func _initialize() -> void:
	LegacyRulesFixture.install(root)
	await _run_case(
		"remote-house building and sub-house upgrade candidates use the real Match bus",
		4,
		_test_remote_catalog_candidates
	)
	await _run_case(
		"the local sidebar remains limited to its local candidate roster",
		2,
		_test_local_sidebar_stays_filtered
	)
	await _run_case(
		"building queue progress reaches the local sidebar option state",
		2,
		_test_building_queue_progress_reaches_sidebar
	)
	if _failures > 0:
		printerr("Catalog availability tests: %d failures after %d assertions" % [_failures, _assertions])
		quit(1)
		return
	print("Catalog availability tests: %d assertions passed" % _assertions)
	quit(0)


func _run_case(case_name: String, expected_assertions: int, test: Callable) -> void:
	_current_case = case_name
	var failures_before := _failures
	var assertions_before := _assertions
	await test.call()
	var actual_assertions := _assertions - assertions_before
	if actual_assertions != expected_assertions:
		_failures += 1
		printerr("FAIL: %s: case ended after %d assertions; expected %d" % [
			case_name, actual_assertions, expected_assertions,
		])
		return
	if _failures == failures_before:
		print("PASS: %s" % case_name)


func _expect(condition: bool, message: String) -> void:
	_assertions += 1
	if condition:
		return
	_failures += 1
	printerr("FAIL: %s: %s" % [_current_case, message])


func _test_remote_catalog_candidates() -> void:
	var match_instance = await _new_match()
	_add_remote_building_prerequisites(match_instance)
	_add_remote_ix_res_centre(match_instance)
	await process_frame
	match_instance.advance_ticks(1)

	_submit_build(match_instance, 2, &"IXResCentre")
	match_instance.advance_ticks(1)
	var building_controller = match_instance.get_node("BuildingController") as BuildingController
	_expect(
		building_controller.building_queue_for_player(2).current_order() != null,
		"player 2's own sub-house IXResCentre order must land in player 2's queue"
	)
	_expect(
		building_controller.building_queue_for_player(1).current_order() == null,
		"control: player 2's building order must leave player 1's queue empty"
	)

	_submit_upgrade(match_instance, 2, &"IXResCentre")
	match_instance.advance_ticks(1)
	var upgrades = match_instance.get_node("UpgradeProductionSystem")
	_expect(
		upgrades.current_order_for_player(2) != null,
		"player 2's own sub-house IXResCentre upgrade must land in player 2's queue"
	)
	_expect(
		upgrades.current_order_for_player(1) == null,
		"control: player 2's upgrade order must leave player 1's queue empty"
	)
	await _free_match(match_instance)


func _test_local_sidebar_stays_filtered() -> void:
	var match_instance = await _new_match()
	var side_panel = match_instance.get_node("HUD/SidePanel")
	_expect(
		not side_panel._building_option_ids.has(&"IXResCentre"),
		"the local Atreides building grid must not render the remote Ix research centre"
	)
	_expect(
		not side_panel._upgrade_option_ids.has(&"IXResCentre"),
		"the local Atreides upgrade grid must not render player 2's Ix upgrade"
	)
	await _free_match(match_instance)


func _test_building_queue_progress_reaches_sidebar() -> void:
	var match_instance = await _new_match()
	match_instance.advance_ticks(1)
	var controller = match_instance.get_node("BuildingController") as BuildingController
	var observed_progress: Array[float] = []
	controller.building_option_state_changed.connect(func(option_state) -> void:
		if option_state.building_id == &"ATBarracks" and option_state.progress > 0.0:
			observed_progress.append(option_state.progress)
	)
	_submit_build(match_instance, 1, &"ATBarracks")
	for _tick in 100:
		match_instance.advance_ticks(1)
		if observed_progress.size() >= 3:
			break
	_expect(observed_progress.size() >= 3, "queue progress must emit at least three sidebar states")
	var strictly_increases := true
	for index in range(1, observed_progress.size()):
		if observed_progress[index] <= observed_progress[index - 1]:
			strictly_increases = false
	_expect(strictly_increases, "emitted sidebar progress must strictly increase while the order runs")
	await _free_match(match_instance)


func _new_match():
	var match_instance := MatchFixtureScene.instantiate()
	root.add_child(match_instance)
	await process_frame
	await process_frame
	return match_instance


func _free_match(match_instance) -> void:
	match_instance.queue_free()
	await process_frame


func _add_remote_building_prerequisites(match_instance) -> void:
	var buildings = match_instance.get_node("Buildings") as Node3D
	var con_yard := ORConYardScene.instantiate() as Building
	con_yard.owner_player_id = 2
	con_yard.position = Vector3(80.0, 8.0, 40.0)
	buildings.add_child(con_yard)
	var windtrap := ORSmWindtrapScene.instantiate() as Building
	windtrap.owner_player_id = 2
	windtrap.position = Vector3(88.0, 8.0, 40.0)
	buildings.add_child(windtrap)
	var factory := ORFactoryScene.instantiate() as Building
	factory.owner_player_id = 2
	factory.position = Vector3(96.0, 8.0, 40.0)
	buildings.add_child(factory)


func _add_remote_ix_res_centre(match_instance) -> void:
	var res_centre := IXResCentreScene.instantiate() as Building
	res_centre.owner_player_id = 2
	res_centre.position = Vector3(96.0, 8.0, 40.0)
	(match_instance.get_node("Buildings") as Node3D).add_child(res_centre)
	res_centre.finish_construction()


func _submit_build(match_instance, player_id: int, building_id: StringName) -> void:
	var command := SimBuildOrderCommandScript.new()
	command.player_id = player_id
	command.building_id = building_id
	command.button_index = MOUSE_BUTTON_LEFT
	match_instance._command_bus.submit(command, match_instance.next_orderable_tick())


func _submit_upgrade(match_instance, player_id: int, upgrade_id: StringName) -> void:
	var command := SimUpgradeOrderCommandScript.new()
	command.player_id = player_id
	command.upgrade_id = upgrade_id
	command.button_index = MOUSE_BUTTON_LEFT
	match_instance._command_bus.submit(command, match_instance.next_orderable_tick())
