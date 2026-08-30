extends SceneTree

## Slice D5's binding regression. These cases submit remote repair and sale
## commands to the real Match bus and drive Match.advance_ticks()
## directly, so they prove the command's player id reaches the execution path
## rather than merely exercising a controller helper in isolation.

const LegacyRulesFixture := preload("res://tests/support/legacy_rules_fixture.gd")
const MatchFixtureScene := preload("res://tests/fixtures/match_fixture.tscn")
const SimRepairBuildingCommandScript := preload("res://scripts/sim/commands/repair_building_command.gd")
const SimSellBuildingCommandScript := preload("res://scripts/sim/commands/sell_building_command.gd")
const ATConYardScene := preload("res://assets/converted/buildings/ATConYard/ATConYard.scn")
const ATSmWindtrapScene := preload("res://assets/converted/buildings/ATSmWindtrap/ATSmWindtrap.scn")

var _assertions := 0
var _failures := 0
var _current_case := ""


func _initialize() -> void:
	LegacyRulesFixture.install(root)
	await _run_case(
		"repair pulses charge each damaged building's owner through the real Match tick",
		_test_repairs_charge_each_owner
	)
	await _run_case(
		"a player-2 repair command is accepted through the real Match bus",
		_test_remote_repair_command_is_accepted
	)
	await _run_case(
		"remote building commands mutate their own world state without writing the local status sidebar",
		_test_remote_commands_do_not_emit_local_status
	)
	await _run_case(
		"a player-2 sale refunds player 2 through the real Match bus",
		_test_remote_sale_refunds_owner
	)
	await _run_case(
		"a player-2 sale starts while player 1 already has a sale in flight",
		_test_concurrent_sales_are_per_player
	)
	if _failures > 0:
		printerr("Building command ownership tests: %d failures after %d assertions" % [_failures, _assertions])
		quit(1)
		return
	print("Building command ownership tests: %d assertions passed" % _assertions)
	quit(0)


func _run_case(case_name: String, test: Callable) -> void:
	_current_case = case_name
	var failures_before := _failures
	var assertions_before := _assertions
	await test.call()
	if _assertions == assertions_before:
		_failures += 1
		printerr("FAIL: %s: the case ended before asserting anything" % case_name)
		return
	if _failures == failures_before:
		print("PASS: %s" % case_name)


func _expect(condition: bool, message: String) -> void:
	_assertions += 1
	if condition:
		return
	_failures += 1
	printerr("FAIL: %s: %s" % [_current_case, message])


func _test_repairs_charge_each_owner() -> void:
	var match_instance = await _new_match()
	var local_building := match_instance.get_node("Buildings/ATSmWindtrap") as Building
	var remote_building := await _add_remote_windtrap(match_instance)
	local_building.health = local_building.max_health - 100.0
	remote_building.health = remote_building.max_health - 100.0
	local_building.is_repairing = true
	remote_building.is_repairing = false
	var players = root.get_node("Players")
	var player_one = players.player(1)
	var player_two = players.player(2)
	var player_one_before: int = player_one.money
	var player_two_before: int = player_two.money
	_submit_repair(match_instance, remote_building, 2)
	_expect(remote_building.is_repairing, "setup: player-2's repair command must start player 2's repair")
	# ATSmWindtrap's 12-health pulse costs 0.6 credits, so two pulses are
	# needed to cross the service's integer-credit carry boundary.
	match_instance.advance_ticks(20)
	var player_one_spent: int = player_one_before - player_one.money
	var player_two_spent: int = player_two_before - player_two.money
	_expect(local_building.health > local_building.max_health - 100.0, "setup: player 1's damaged building must repair")
	_expect(remote_building.health > remote_building.max_health - 100.0, "setup: player 2's damaged building must repair")
	_expect(player_one_spent > 0, "setup: a repair pulse must charge player 1 something")
	_expect(player_two_spent > 0, "player 2 must pay for player 2's damaged building")
	_expect(player_one_spent == player_two_spent, "player 1's fixture credits must not also pay for player 2's identical building")
	await _free_match(match_instance)


func _test_remote_repair_command_is_accepted() -> void:
	var match_instance = await _new_match()
	var remote_building := await _add_remote_conyard(match_instance)
	remote_building.health = remote_building.max_health - 100.0
	remote_building.is_repairing = false
	_submit_repair(match_instance, remote_building, 2)
	_expect(remote_building.is_repairing, "a player-2 repair command must toggle player 2's damaged building on")
	await _free_match(match_instance)


func _test_remote_commands_do_not_emit_local_status() -> void:
	var match_instance = await _new_match()
	var controller = match_instance.get_node("BuildingController") as BuildingController
	var local_building := match_instance.get_node("Buildings/ATSmWindtrap") as Building
	var remote_building := await _add_remote_conyard(match_instance)
	remote_building.health = remote_building.max_health - 100.0
	var statuses: Array[String] = []
	controller.status_changed.connect(func(status: String) -> void: statuses.append(status))
	_submit_repair(match_instance, remote_building, 2)
	_expect(remote_building.is_repairing, "an accepted remote repair must still mutate player 2's building")
	_expect(statuses.is_empty(), "an accepted remote repair must not write player 1's status sidebar")
	local_building.health = local_building.max_health - 100.0
	local_building.is_repairing = false
	_submit_repair(match_instance, local_building, 2)
	_expect(not local_building.is_repairing, "an invalid remote repair must still be refused by ownership")
	_expect(statuses.is_empty(), "an invalid remote repair must not write player 1's status sidebar")
	_submit_sale(match_instance, local_building, 2)
	_expect(local_building.is_construction_complete(), "an invalid remote sale must still be refused by ownership")
	_expect(statuses.is_empty(), "an invalid remote sale must not write player 1's status sidebar")
	await _free_match(match_instance)


func _test_remote_sale_refunds_owner() -> void:
	var match_instance = await _new_match()
	var remote_building := await _add_remote_conyard(match_instance)
	var players = root.get_node("Players")
	var player_one = players.player(1)
	var player_two = players.player(2)
	var player_one_before: int = player_one.money
	var player_two_before: int = player_two.money
	_submit_sale(match_instance, remote_building, 2)
	_finish_sale(match_instance, remote_building)
	_expect(player_two.money > player_two_before, "a completed player-2 sale must refund player 2")
	_expect(player_one.money == player_one_before, "control: player 1's fixture credits must stay untouched by player 2's refund")
	_expect(remote_building.is_simulation_halted(), "the player-2 building must actually be sold, not merely credited")
	await _free_match(match_instance)


func _test_concurrent_sales_are_per_player() -> void:
	var match_instance = await _new_match()
	var local_building := match_instance.get_node("Buildings/ATSmWindtrap") as Building
	var remote_building := await _add_remote_conyard(match_instance)
	_submit_sale(match_instance, local_building, 1)
	var local_halted_after_start := local_building.is_simulation_halted()
	var local_queued_after_start := local_building.is_queued_for_deletion()
	var local_animation_after_start := (local_building.get_node("StatePlayer") as AnimationPlayer).current_animation
	_submit_sale(match_instance, remote_building, 2)
	_expect(not remote_building.is_construction_complete(), "player 2's sale must start even while player 1's sale is in flight")
	_expect(local_building.is_simulation_halted() == local_halted_after_start, "after player 1's sale has started, player 2's command must not complete player 1's sale")
	_expect(local_building.is_queued_for_deletion() == local_queued_after_start, "after player 1's sale has started, player 2's command must not despawn player 1's building")
	_expect((local_building.get_node("StatePlayer") as AnimationPlayer).current_animation == local_animation_after_start, "after player 1's sale has started, player 2's command must not advance player 1's sale animation")
	await _free_match(match_instance)


func _new_match():
	var match_instance := MatchFixtureScene.instantiate()
	root.add_child(match_instance)
	for _warmup in 3:
		await process_frame
	return match_instance


func _add_remote_windtrap(match_instance) -> Building:
	var building := ATSmWindtrapScene.instantiate() as Building
	building.owner_player_id = 2
	building.position = Vector3(48.0, 8.0, 12.0)
	match_instance.get_node("Buildings").add_child(building)
	await process_frame
	return building


func _add_remote_conyard(match_instance) -> Building:
	var building := ATConYardScene.instantiate() as Building
	building.owner_player_id = 2
	building.position = Vector3(48.0, 8.0, 12.0)
	match_instance.get_node("Buildings").add_child(building)
	await process_frame
	return building


func _submit_repair(match_instance, building: Building, player_id: int) -> void:
	var command := SimRepairBuildingCommandScript.new()
	command.player_id = player_id
	command.entity_id = building.entity_id
	match_instance._command_bus.submit(command, match_instance.next_orderable_tick())
	match_instance.advance_ticks(1)


func _submit_sale(match_instance, building: Building, player_id: int) -> void:
	var command := SimSellBuildingCommandScript.new()
	command.player_id = player_id
	command.entity_id = building.entity_id
	match_instance._command_bus.submit(command, match_instance.next_orderable_tick())
	match_instance.advance_ticks(1)


func _finish_sale(match_instance, building: Building) -> void:
	var player := building.get_node_or_null("StatePlayer") as AnimationPlayer
	_expect(player != null, "setup: the sale fixture must provide a StatePlayer")
	if player == null:
		return
	player.animation_finished.emit(&"sell")
	match_instance.advance_ticks(1)


func _free_match(match_instance) -> void:
	match_instance.queue_free()
	await process_frame
