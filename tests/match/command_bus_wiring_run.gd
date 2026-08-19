extends SceneTree

## Proves the phase 2 command-bus wiring -- SimCommandBus
## (scripts/sim/command_bus.gd), CommandExecutor
## (scripts/match/command_executor.gd) and the drain point in
## Match._advance_simulation_tick() -- without calling the bus or the
## executor itself anywhere in this file. Every case here only ever drives
## the real UnitCommandController (through handle_unhandled_input(), the
## same entry point a real S keypress uses) and the real Match tick loop
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
