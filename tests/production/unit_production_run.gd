extends SceneTree

const LegacyRulesFixture := preload("res://tests/support/legacy_rules_fixture.gd")
const MatchFixtureScene := preload("res://tests/fixtures/match_fixture.tscn")
const SimUnitOrderCommandScript := preload("res://scripts/sim/commands/unit_order_command.gd")
const ATBarracksScene := preload("res://assets/converted/buildings/ATBarracks/ATBarracks.scn")

var _assertions := 0
var _failures := 0
var _current_case := ""


func _initialize() -> void:
	LegacyRulesFixture.install(root)
	await _run_case(
		"a player-2 unit order owns its queue, credits, producer and spawned unit through the real match bus",
		6,
		_test_player_two_unit_order_owns_everything
	)
	await _run_case(
		"unit queue progress reaches the local sidebar option state",
		2,
		_test_unit_queue_progress_reaches_sidebar
	)
	await _run_case(
		"a completion refreshes the sidebar from the next queued unit order",
		2,
		_test_completion_refreshes_next_queued_option_state
	)
	await _run_case(
		"unit availability follows the command player rather than the local sidebar player",
		2,
		_test_unit_availability_follows_command_player
	)
	if _failures > 0:
		printerr("Unit production tests: %d failures after %d assertions" % [_failures, _assertions])
		quit(1)
		return
	print("Unit production tests: %d assertions passed" % _assertions)
	quit(0)


func _run_case(case_name: String, expected_assertions: int, test: Callable) -> void:
	_current_case = case_name
	var failures_before := _failures
	var assertions_before := _assertions
	await test.call()
	var actual_assertions := _assertions - assertions_before
	if actual_assertions != expected_assertions:
		_failures += 1
		printerr(
			"FAIL: %s: case ended after %d assertions; expected %d" % [
				case_name, actual_assertions, expected_assertions,
			]
		)
		return
	if _failures == failures_before:
		print("PASS: %s" % case_name)


func _expect(condition: bool, message: String) -> void:
	_assertions += 1
	if condition:
		return
	_failures += 1
	printerr("FAIL: %s: %s" % [_current_case, message])


func _test_player_two_unit_order_owns_everything() -> void:
	var match_instance := MatchFixtureScene.instantiate()
	get_root().add_child(match_instance)
	await process_frame
	await process_frame
	var players = get_root().get_node("Players")
	var player_one = players.player(1)
	var player_two = players.player(2)
	var producers := _add_barracks_for_both_players(match_instance)
	await process_frame
	match_instance._advance_simulation_tick()

	var player_one_money_before: int = player_one.money
	var player_two_money_before: int = player_two.money
	var units_before := (match_instance.get_node("Units") as Node).get_children().duplicate()
	var command := SimUnitOrderCommandScript.new()
	command.player_id = 2
	command.unit_id = &"ATInfantry"
	command.button_index = MOUSE_BUTTON_LEFT
	match_instance._command_bus.submit(command, match_instance.next_orderable_tick())
	match_instance._advance_simulation_tick()

	var production = match_instance.get_node_or_null("UnitProductionSystem")
	_expect(
		_unit_queue_size(production, match_instance, 2, &"ATBarracks") == 1,
		"player 2's order must land in player 2's queue"
	)
	_expect(
		_unit_queue_size(production, match_instance, 1, &"ATBarracks") == 0,
		"player 1's queue must stay untouched by player 2's order"
	)
	for _tick in 2000:
		match_instance._advance_simulation_tick()
		if _newest_unit(match_instance, &"ATInfantry", units_before) != null:
			break
	var produced := _newest_unit(match_instance, &"ATInfantry", units_before)
	_expect(player_two.money < player_two_money_before, "player 2 must pay from player 2 credits")
	_expect(produced != null and produced.owner_player_id == 2, "completed unit must be owned by player 2")
	_expect(
		produced != null and produced.global_position.is_equal_approx(producers.player_two.production_spawn_position()),
		"completed unit must spawn from player 2's production building"
	)
	_expect(
		player_one.money == player_one_money_before,
		"control: player 1 fixture credits must stay untouched by player 2's order"
	)
	match_instance.queue_free()
	await process_frame


func _test_unit_queue_progress_reaches_sidebar() -> void:
	var match_instance := MatchFixtureScene.instantiate()
	get_root().add_child(match_instance)
	await process_frame
	await process_frame
	_add_barracks_for_both_players(match_instance)
	await process_frame
	match_instance._advance_simulation_tick()
	var roster = match_instance.get_node("UnitRosterController")
	var observed_progress: Array[float] = []
	roster.unit_option_state_changed.connect(func(option_state) -> void:
		if option_state.building_id == &"ATInfantry" and option_state.progress > 0.0:
			observed_progress.append(option_state.progress)
	)
	var command := SimUnitOrderCommandScript.new()
	command.player_id = 1
	command.unit_id = &"ATInfantry"
	command.button_index = MOUSE_BUTTON_LEFT
	match_instance._command_bus.submit(command, match_instance.next_orderable_tick())
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
	match_instance.queue_free()
	await process_frame


func _test_completion_refreshes_next_queued_option_state() -> void:
	var match_instance := MatchFixtureScene.instantiate()
	get_root().add_child(match_instance)
	await process_frame
	await process_frame
	_add_barracks_for_both_players(match_instance)
	await process_frame
	match_instance._advance_simulation_tick()
	var roster = match_instance.get_node("UnitRosterController")
	var production = match_instance.get_node("UnitProductionSystem")
	var observed := {"latest_infantry_state": null}
	var completion_states: Array[BuildingOptionState] = []
	roster.unit_option_state_changed.connect(func(option_state: BuildingOptionState) -> void:
		if option_state.building_id == &"ATInfantry":
			observed["latest_infantry_state"] = option_state
	)
	production.unit_order_execution.connect(func(player_id: int, execution) -> void:
		if player_id == 1 and execution.kind == UnitProductionSystem.UnitOrderOutcome.COMPLETED:
			completion_states.append(observed["latest_infantry_state"] as BuildingOptionState)
	)
	var command := SimUnitOrderCommandScript.new()
	command.player_id = 1
	command.unit_id = &"ATInfantry"
	command.button_index = MOUSE_BUTTON_LEFT
	command.quantity = 2
	match_instance._command_bus.submit(command, match_instance.next_orderable_tick())
	for _tick in 2000:
		match_instance._advance_simulation_tick()
		if not completion_states.is_empty():
			break
	_expect(completion_states.size() == 1, "the first completed order must emit one sidebar refresh")
	var post_completion = completion_states[0] if not completion_states.is_empty() else null
	_expect(
		post_completion != null
		and post_completion.state == BuildingOptionState.State.PROGRESS
		and post_completion.quantity == 1,
		"the completion refresh must show the next queued order as active"
	)
	match_instance.queue_free()
	await process_frame


func _test_unit_availability_follows_command_player() -> void:
	var match_instance := MatchFixtureScene.instantiate()
	get_root().add_child(match_instance)
	await process_frame
	await process_frame
	_add_barracks_for_player(match_instance, 2, Vector3(80.0, 8.0, 40.0))
	await process_frame
	match_instance._advance_simulation_tick()
	var production = match_instance.get_node("UnitProductionSystem")
	var player_two_order := SimUnitOrderCommandScript.new()
	player_two_order.player_id = 2
	player_two_order.unit_id = &"ATInfantry"
	player_two_order.button_index = MOUSE_BUTTON_LEFT
	match_instance._command_bus.submit(player_two_order, match_instance.next_orderable_tick())
	match_instance._advance_simulation_tick()
	_expect(
		_unit_queue_size(production, match_instance, 2, &"ATBarracks") == 1,
		"the player with the prerequisite must have the real-bus order accepted"
	)
	var player_one_order := SimUnitOrderCommandScript.new()
	player_one_order.player_id = 1
	player_one_order.unit_id = &"ATInfantry"
	player_one_order.button_index = MOUSE_BUTTON_LEFT
	match_instance._command_bus.submit(player_one_order, match_instance.next_orderable_tick())
	match_instance._advance_simulation_tick()
	_expect(
		_unit_queue_size(production, match_instance, 1, &"ATBarracks") == 0,
		"the player without the prerequisite must have the real-bus order refused"
	)
	match_instance.queue_free()
	await process_frame


func _add_barracks_for_both_players(match_instance) -> Dictionary:
	var buildings := match_instance.get_node("Buildings") as Node3D
	var player_one := ATBarracksScene.instantiate() as Building
	var player_two := ATBarracksScene.instantiate() as Building
	player_one.position = Vector3(48.0, 8.0, 40.0)
	player_two.position = Vector3(80.0, 8.0, 40.0)
	player_one.owner_player_id = 1
	player_two.owner_player_id = 2
	buildings.add_child(player_one)
	buildings.add_child(player_two)
	player_one.finish_construction()
	player_two.finish_construction()
	return {"player_one": player_one, "player_two": player_two}


func _add_barracks_for_player(match_instance, player_id: int, position: Vector3) -> Building:
	var barracks := ATBarracksScene.instantiate() as Building
	barracks.position = position
	barracks.owner_player_id = player_id
	(match_instance.get_node("Buildings") as Node3D).add_child(barracks)
	barracks.finish_construction()
	return barracks


func _unit_queue_size(production, _match_instance, player_id: int, building_id: StringName) -> int:
	return production.unit_queue_size_for_player(player_id, building_id)


func _newest_unit(match_instance, config_id: StringName, excluded: Array = []) -> Unit:
	var newest: Unit = null
	for candidate in match_instance.get_node("Units").get_children():
		var unit := candidate as Unit
		if unit != null and not excluded.has(unit) and unit.config_id == config_id:
			newest = unit
	return newest
