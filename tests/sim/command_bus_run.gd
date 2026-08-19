extends "res://tests/support/suite.gd"

## Pins down scripts/sim/command_bus.gd, the scheduling and ordering half of
## the phase 2 command spine -- see
## docs/architecture/network-multiplayer.md, phase 2. Pure unit tests:
## SimCommandBus extends RefCounted and touches no scene tree, so this suite
## instantiates it directly with nothing else running. Uses the bare
## SimCommand base throughout to exercise the bus itself, independent of any
## concrete command type -- SimStopCommand gets its own wiring proof in
## tests/match/command_bus_wiring_run.gd.

const SimCommandBusScript := preload("res://scripts/sim/command_bus.gd")
const SimCommandScript := preload("res://scripts/sim/commands/sim_command.gd")


func _initialize() -> void:
	_run_case(
		"a command submitted with delay 0 drains at its target tick, and only there",
		_test_delay_zero_drains_only_at_target_tick
	)
	_run_case("input_delay_ticks shifts the target tick forward", _test_delay_shifts_target_tick)
	_run_case("drain() removes what it returns", _test_drain_removes_what_it_returns)
	_run_case("drain() orders by player_id first", _test_order_by_player_id)
	_run_case(
		"drain() breaks a same-player, same-tick tie by submission sequence",
		_test_sequence_tiebreak
	)
	_run_case("a late submit is dropped, counted, and never drained", _test_late_submit_dropped)
	_run_case("pending_count() tracks submissions and drains", _test_pending_count)
	_finish("SimCommandBus tests")


func _make_command(player_id: int) -> SimCommand:
	var command := SimCommandScript.new()
	command.player_id = player_id
	return command


func _test_delay_zero_drains_only_at_target_tick() -> void:
	var early := SimCommandBusScript.new()
	early.submit(_make_command(1), 10)
	_expect(early.drain(9).is_empty(), "nothing must be due one tick before the target")

	var late := SimCommandBusScript.new()
	late.submit(_make_command(1), 10)
	_expect(late.drain(11).is_empty(), "nothing must be due one tick after the target")

	var on_time := SimCommandBusScript.new()
	var command := _make_command(1)
	var target := on_time.submit(command, 10)
	_expect(target == 10, "delay 0 must target current_tick unchanged")
	var due := on_time.drain(10)
	_expect(due.size() == 1 and due[0] == command, "the command must drain at exactly its target tick")


func _test_delay_shifts_target_tick() -> void:
	var bus := SimCommandBusScript.new()
	bus.input_delay_ticks = 3
	var command := _make_command(1)
	var target := bus.submit(command, 10)
	_expect(target == 13, "submit() must schedule for current_tick + input_delay_ticks")
	_expect(bus.drain(10).is_empty(), "nothing must be due at the unshifted tick")
	var due := bus.drain(13)
	_expect(due.size() == 1 and due[0] == command, "the command must drain at current_tick + input_delay_ticks")


func _test_drain_removes_what_it_returns() -> void:
	var bus := SimCommandBusScript.new()
	bus.submit(_make_command(1), 5)
	var first := bus.drain(5)
	_expect(first.size() == 1, "the command due at tick 5 must be returned once")
	var second := bus.drain(5)
	_expect(second.is_empty(), "drain() must not return the same command a second time")


func _test_order_by_player_id() -> void:
	var bus := SimCommandBusScript.new()
	var high := _make_command(5)
	var low := _make_command(1)
	# Submitted in descending player_id order, so a bus that merely preserved
	# submission order would return them in the wrong sequence -- this proves
	# drain() actually sorts rather than happening to agree with insertion order.
	bus.submit(high, 7)
	bus.submit(low, 7)
	var due := bus.drain(7)
	_expect(due.size() == 2, "both commands due at tick 7 must be returned")
	_expect(due[0] == low and due[1] == high, "drain() must order by player_id ascending")


func _test_sequence_tiebreak() -> void:
	var bus := SimCommandBusScript.new()
	var first := _make_command(2)
	var second := _make_command(2)
	# Same player, same tick: submission sequence is the only thing that can
	# order these two. Submitted first must drain first -- if drain() ever
	# fell back to something unstable (say, Dictionary/Array iteration order
	# with no explicit tiebreak), this is the case that would catch it
	# silently reordering two commands from the same player.
	bus.submit(first, 4)
	bus.submit(second, 4)
	var due := bus.drain(4)
	_expect(due.size() == 2, "both same-player commands due at tick 4 must be returned")
	_expect(due[0] == first and due[1] == second, "same-player commands must drain in submission order")


func _test_late_submit_dropped() -> void:
	var bus := SimCommandBusScript.new()
	# Marks tick 5 as drained even though nothing was due -- see drain()'s
	# comment on why that still has to count for late detection.
	bus.drain(5)
	_expect(bus.dropped_late_count() == 0, "draining an empty tick must not itself count as a drop")

	var late_command := _make_command(1)
	var target := bus.submit(late_command, 5)
	_expect(
		target == 5,
		"submit() still reports the tick current_tick + input_delay_ticks names, even when it refuses to queue it"
	)
	_expect(
		bus.dropped_late_count() == 1,
		"a submit() whose target tick is at or before the last drained tick must be counted as dropped"
	)
	_expect(bus.pending_count() == 0, "a dropped command must never enter the pending queue")
	_expect(bus.drain(5).is_empty(), "a dropped command must never appear in a later drain of its own target tick")


func _test_pending_count() -> void:
	var bus := SimCommandBusScript.new()
	_expect(bus.pending_count() == 0, "a fresh bus must have nothing pending")
	bus.submit(_make_command(1), 6)
	bus.submit(_make_command(2), 6)
	bus.submit(_make_command(1), 7)
	_expect(bus.pending_count() == 3, "pending_count() must grow by one per accepted submit()")
	bus.drain(6)
	_expect(bus.pending_count() == 1, "pending_count() must shrink by exactly what drain() removed")
	bus.drain(7)
	_expect(bus.pending_count() == 0, "pending_count() must reach zero once every submitted tick has been drained")
