extends SceneTree

## Proves the phase 2 command-bus wiring -- SimCommandBus
## (scripts/sim/command_bus.gd), CommandExecutor
## (scripts/match/command_executor.gd) and the drain point in
## Match._advance_simulation_tick(). The Stop cases drive the real
## UnitCommandController through handle_unhandled_input(), the same entry
## point a real S keypress uses. The wall cases submit a SimWallLineCommand
## directly because the second wall click's local picker is not part of this
## fixture; they still execute only through the real Match command bus and
## Match._advance_simulation_tick(), never by calling the controller's command
## handler. All cases use the real Match tick loop
## (through real engine frames, the same way
## tests/match/demo_boot_run.gd's _test_match_loop_drives_the_clock proves
## the clock is actually reached). tests/sim/command_bus_run.gd already
## covers the bus's own scheduling and ordering in isolation; this suite's
## job is only to prove those parts are actually wired together.
##
## Same multi-Match teardown hazard as tests/match/entity_id_run.gd, and the
## same guard: queue_free() defers the actual removal to this frame's
## teardown, and until that runs this Match is still a member of
## MatchLookupScript.GROUP, so the next case's fresh Match could otherwise
## lose the race for get_first_node_in_group() to this one on its way out.

const LegacyRulesFixture := preload("res://tests/support/legacy_rules_fixture.gd")
const MatchFixtureScene := preload("res://tests/fixtures/match_fixture.tscn")
const SimWallLineCommandScript := preload("res://scripts/sim/commands/wall_line_command.gd")
const ATConYardScene := preload("res://assets/converted/buildings/ATConYard/ATConYard.scn")
const ATSmWindtrapScene := preload("res://assets/converted/buildings/ATSmWindtrap/ATSmWindtrap.scn")

var _assertions := 0
var _failures := 0
var _current_case := ""


func _initialize() -> void:
	LegacyRulesFixture.install(root)
	await _run_case(
		"a Stop order issued through the controller does not take effect during the frame it was issued",
		_test_stop_defers_to_the_tick
	)
	await _run_case(
		"a Stop order's status label arrives only once the executing tick runs, not on the issuing frame",
		_test_stop_status_arrives_with_the_tick
	)
	await _run_case(
		"a player-2 wall line spends and places for player 2 through the real match bus",
		_test_player_two_wall_line_owns_credits_and_building
	)
	await _run_case(
		"a player-2 wall line leaves an active local preview and committed click alone",
		_test_player_two_wall_line_does_not_touch_local_preview
	)

	if _failures > 0:
		printerr("Command bus wiring tests: %d failures after %d assertions" % [_failures, _assertions])
		quit(1)
		return
	print("Command bus wiring tests: %d assertions passed" % _assertions)
	quit(0)


func _run_case(case_name: String, test: Callable) -> void:
	_current_case = case_name
	var failures_before := _failures
	var assertions_before := _assertions
	await test.call()
	# A runtime error aborts the case function where it stands, leaving
	# _failures untouched -- which would print PASS for a case that never
	# reached an assertion. tests/support/suite.gd guards against this and
	# this suite cannot extend it (its cases await), so the guard is repeated
	# here rather than dropped: a wiring test that can pass by crashing
	# defeats its own reason to exist.
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


func _key_event(keycode: Key, pressed: bool) -> InputEventKey:
	var event := InputEventKey.new()
	event.keycode = keycode
	event.pressed = pressed
	return event


## Waits for real engine frames (never a direct call into Match's tick
## internals) until current_tick() has advanced past `started_tick`, bounded
## so a broken drain fails this assertion instead of hanging the suite --
## the same bounded-real-time idiom
## tests/match/demo_boot_run.gd::_test_match_loop_drives_the_clock uses to
## prove the real match loop actually reaches the tick.
func _await_next_tick(match_instance, started_tick: int) -> void:
	var started_msec := Time.get_ticks_msec()
	while match_instance.current_tick() <= started_tick and Time.get_ticks_msec() - started_msec < 500:
		await process_frame


func _test_stop_defers_to_the_tick() -> void:
	var match_instance := MatchFixtureScene.instantiate()
	get_root().add_child(match_instance)
	for _warmup in 5:
		await process_frame

	var scout := match_instance.get_node("Units/ScoutA")
	# A manufactured order, not a real navigation route: cancel_all_orders()
	# (scripts/units/unit.gd) treats _has_pending_navigation_order as one of
	# three independent reasons an order counts as active, so setting it
	# directly gives Stop something real to cancel without needing a real
	# navigation destination to resolve first.
	scout._has_pending_navigation_order = true

	var unit_command_controller = match_instance._unit_command_controller
	var selection: Array[Node] = [scout]
	unit_command_controller._set_selection(selection)

	var tick_before_issue: int = match_instance.current_tick()
	_expect(
		unit_command_controller.handle_unhandled_input(_key_event(KEY_S, true)),
		"an S press must be consumed as a unit command"
	)

	_expect(
		scout._has_pending_navigation_order,
		"issuing Stop must not cancel the order on the same frame it was issued -- only the scheduled tick may do that"
	)

	await _await_next_tick(match_instance, tick_before_issue)

	_expect(
		not scout._has_pending_navigation_order,
		"the order must be cancelled once the simulation tick this command was scheduled for actually runs"
	)

	match_instance.queue_free()
	await process_frame


func _test_stop_status_arrives_with_the_tick() -> void:
	var match_instance := MatchFixtureScene.instantiate()
	get_root().add_child(match_instance)
	for _warmup in 5:
		await process_frame

	var scout := match_instance.get_node("Units/ScoutA")
	scout._has_pending_navigation_order = true

	var unit_command_controller = match_instance._unit_command_controller
	var selection: Array[Node] = [scout]
	unit_command_controller._set_selection(selection)

	var statuses: Array[String] = []
	unit_command_controller.status_changed.connect(func(status: String) -> void: statuses.append(status))

	var tick_before_issue: int = match_instance.current_tick()
	unit_command_controller.handle_unhandled_input(_key_event(KEY_S, true))

	_expect(
		statuses.is_empty(),
		"no status must be reported on the same frame Stop was issued -- CommandExecutor has not run yet"
	)

	await _await_next_tick(match_instance, tick_before_issue)

	_expect(
		statuses.has("Stopped"),
		"the 'Stopped' status must arrive once the tick executes the command and hands its result back through on_command_executed()"
	)

	match_instance.queue_free()
	await process_frame


func _test_player_two_wall_line_owns_credits_and_building() -> void:
	var match_instance: Variant = await _wall_match()
	var controller = match_instance.get_node("BuildingController") as BuildingController
	var wall_cell: Variant = _wall_cell(match_instance, controller)
	_expect(wall_cell != null, "setup: the fixture must provide a buildable Wall cell")
	if wall_cell == null:
		await _free_match(match_instance)
		return
	var players = get_root().get_node("Players")
	var player_one = players.player(1)
	var player_two = players.player(2)
	var player_one_money_before: int = player_one.money
	var player_two_money_before: int = player_two.money
	_submit_wall_line(match_instance, wall_cell)
	var remote_queue = controller.building_queue_for_player(2)
	var local_queue = controller.building_queue_for_player(1)
	_expect(remote_queue != local_queue, "setup: player 1 and player 2 must keep distinct production queues")
	_expect(remote_queue.has_order(), "the player-2 wall line must start in player 2's queue")
	var placed := _advance_until_wall(match_instance)
	_expect(placed != null and placed.owner_player_id == 2, "the wall placed by player 2's command must be owned by player 2")
	_expect(player_two.money < player_two_money_before, "player 2 must pay the wall chain from their own credits")
	_expect(player_one.money == player_one_money_before, "control: player 1's fixture credits must stay untouched by player 2's wall line")
	await _free_match(match_instance)


func _test_player_two_wall_line_does_not_touch_local_preview() -> void:
	var match_instance: Variant = await _wall_match()
	var controller = match_instance.get_node("BuildingController") as BuildingController
	var wall_cell: Variant = _wall_cell(match_instance, controller)
	_expect(wall_cell != null, "setup: the fixture must provide a buildable Wall cell")
	if wall_cell == null:
		await _free_match(match_instance)
		return
	var local_queue = controller.building_queue_for_player(1)
	local_queue.start(&"ATBarracks", "Local preview", 0, 1)
	local_queue.advance_tick(0)
	controller._begin_ready_building_placement()
	_expect(controller._building_placement.is_active(), "setup: a real local ready order must open the local preview")
	var committed_cell := Vector2i(wall_cell.x + 1, wall_cell.y + 1)
	controller._committed_placement_cell = committed_cell
	_submit_wall_line(match_instance, wall_cell)
	var placed := _advance_until_wall(match_instance)
	_expect(placed != null and placed.owner_player_id == 2, "player 2's wall must still place")
	_expect(controller._building_placement.is_active(), "player 2's wall line must leave the local preview active")
	_expect(controller._committed_placement_cell == committed_cell, "player 2's wall line must leave the committed click unchanged")
	await _free_match(match_instance)


func _wall_match():
	var match_instance := MatchFixtureScene.instantiate()
	get_root().add_child(match_instance)
	await process_frame
	await process_frame
	var buildings := match_instance.get_node("Buildings") as Node3D
	var local_yard := buildings.get_node("ATConYard") as Building
	var local_windtrap := buildings.get_node("ATSmWindtrap") as Building
	var con_yard := ATConYardScene.instantiate() as Building
	con_yard.owner_player_id = 2
	con_yard.position = local_yard.position
	buildings.add_child(con_yard)
	var windtrap := ATSmWindtrapScene.instantiate() as Building
	windtrap.owner_player_id = 2
	windtrap.position = local_windtrap.position
	buildings.add_child(windtrap)
	await process_frame
	return match_instance


func _wall_cell(match_instance, controller: BuildingController):
	var config = controller._building_config(&"ATWall")
	var rows: Array[String] = controller._building_occupy_rows(config)
	if not controller._building_placement.begin(&"ATWall", "Wall", rows, true):
		return null
	var grid = match_instance.terrain.navigation_grid
	var center: Vector2i = grid.world_to_grid((match_instance.get_node("Buildings/ATConYard") as Building).global_position)
	for radius in range(4, 24):
		for x in range(-radius, radius + 1):
			for y in [-radius, radius]:
				var candidate: Vector2i = center + Vector2i(x, y)
				if controller._building_placement.evaluate_at_hover_cell(candidate) == BuildingPlacement.PlaceResult.AVAILABLE:
					controller._building_placement.cancel()
					return candidate
	controller._building_placement.cancel()
	return null


func _submit_wall_line(match_instance, wall_cell: Vector2i) -> void:
	var command := SimWallLineCommandScript.new()
	command.player_id = 2
	command.building_id = &"ATWall"
	command.start_cell = wall_cell
	command.end_cell = wall_cell
	match_instance._command_bus.submit(command, match_instance.next_orderable_tick())
	match_instance.advance_ticks(1)


func _advance_until_wall(match_instance) -> Building:
	for _tick in 2000:
		match_instance.advance_ticks(1)
		for node in match_instance.get_node("Buildings").get_children():
			var building := node as Building
			if building != null and building.config_id == &"ATWall":
				return building
	return null


func _free_match(match_instance) -> void:
	match_instance.queue_free()
	await process_frame
