extends SceneTree

## Binding regressions use a real Match and real command bus; CommandPump has
## its own bus and cannot prove Match's central tick wiring.
const LegacyRulesFixture := preload("res://tests/support/legacy_rules_fixture.gd")
const MatchFixtureScene := preload("res://tests/fixtures/match_fixture.tscn")
const SimUpgradeOrderCommandScript := preload("res://scripts/sim/commands/upgrade_order_command.gd")
const ATConYardScene := preload("res://assets/converted/buildings/ATConYard/ATConYard.scn")
const ATRefineryScene := preload("res://assets/converted/buildings/ATRefinery/ATRefinery.scn")

var _assertions := 0
var _failures := 0
var _current_case := ""


func _initialize() -> void:
	LegacyRulesFixture.install(root)
	await _run_case(
		"a player-2 upgrade order owns its queue, credits and purchased upgrade through the real match bus",
		5,
		_test_player_two_global_upgrade_owns_everything
	)
	await _run_case(
		"a player-2 dock order binds and completes on player 2's refinery only",
		3,
		_test_player_two_dock_binds_to_its_owner
	)
	await _run_case(
		"upgrade queue progress reaches the local sidebar option state",
		2,
		_test_upgrade_queue_progress_reaches_sidebar
	)
	if _failures > 0:
		printerr("Upgrade production tests: %d failures after %d assertions" % [_failures, _assertions])
		quit(1)
		return
	print("Upgrade production tests: %d assertions passed" % _assertions)
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


func _test_player_two_global_upgrade_owns_everything() -> void:
	var match_instance: Variant = await _new_match()
	var players = root.get_node("Players")
	var player_one = players.player(1)
	var player_two = players.player(2)
	_add_con_yard(match_instance, 2, Vector3(80.0, 8.0, 40.0))
	await process_frame
	match_instance._advance_simulation_tick()
	var player_one_money_before: int = player_one.money
	var player_two_money_before: int = player_two.money
	_submit(match_instance, 2, &"ATConYard")
	match_instance._advance_simulation_tick()
	var production = match_instance.get_node("UpgradeProductionSystem")
	_expect(
		production.current_order_for_player(2) != null
		and production.current_order_for_player(1) == null,
		"player 2's order must land in player 2's queue and leave player 1's untouched"
	)
	for _tick in 400:
		match_instance._advance_simulation_tick()
		if player_two.has_purchased_upgrade(&"ATConYard"):
			break
	_expect(player_two.money < player_two_money_before, "player 2 must pay from player 2 credits")
	_expect(player_two.has_purchased_upgrade(&"ATConYard"), "player 2 must receive the completed purchase")
	_expect(not player_one.has_purchased_upgrade(&"ATConYard"), "control: player 1 must not receive player 2's purchase")
	_expect(player_one.money == player_one_money_before, "control: player 1 fixture credits must stay untouched")
	await _free_match(match_instance)


func _test_player_two_dock_binds_to_its_owner() -> void:
	var match_instance: Variant = await _new_match()
	var player_one_refinery := _add_refinery(match_instance, 1, Vector3(48.0, 8.0, 40.0))
	var player_two_refinery := _add_refinery(match_instance, 2, Vector3(80.0, 8.0, 40.0))
	await process_frame
	match_instance._advance_simulation_tick()
	_submit(match_instance, 2, &"ATRefineryDock")
	match_instance._advance_simulation_tick()
	var production = match_instance.get_node("UpgradeProductionSystem")
	var dock_order = production.current_order_for_player(2)
	_expect(
		dock_order != null and dock_order.target_refinery == player_two_refinery.entity_id,
		"player 2's dock order must bind to player 2's refinery entity id"
	)
	for _tick in 320:
		match_instance._advance_simulation_tick()
		if player_two_refinery.refinery_upgrade_state == 1:
			break
	_expect(player_two_refinery.refinery_upgrade_state == 1, "player 2's refinery must receive the dock")
	_expect(player_one_refinery.refinery_upgrade_state == 0, "control: player 1's refinery must stay untouched")
	await _free_match(match_instance)


func _test_upgrade_queue_progress_reaches_sidebar() -> void:
	var match_instance: Variant = await _new_match()
	match_instance._advance_simulation_tick()
	var controller = match_instance.get_node("BuildingUpgradeController")
	var observed_progress: Array[float] = []
	controller.upgrade_option_state_changed.connect(func(option_state) -> void:
		if option_state.building_id == &"ATConYard" and option_state.progress > 0.0:
			observed_progress.append(option_state.progress)
	)
	_submit(match_instance, 1, &"ATConYard")
	for _tick in 100:
		match_instance._advance_simulation_tick()
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


func _add_con_yard(match_instance, player_id: int, position: Vector3) -> Building:
	var building := ATConYardScene.instantiate() as Building
	building.position = position
	building.owner_player_id = player_id
	(match_instance.get_node("Buildings") as Node).add_child(building)
	building.finish_construction()
	return building


func _add_refinery(match_instance, player_id: int, position: Vector3) -> Building:
	var building := ATRefineryScene.instantiate() as Building
	building.position = position
	building.owner_player_id = player_id
	(match_instance.get_node("Buildings") as Node).add_child(building)
	building.finish_construction()
	return building


func _submit(match_instance, player_id: int, upgrade_id: StringName) -> void:
	var command := SimUpgradeOrderCommandScript.new()
	command.player_id = player_id
	command.upgrade_id = upgrade_id
	command.button_index = MOUSE_BUTTON_LEFT
	match_instance._command_bus.submit(command, match_instance.next_orderable_tick())
