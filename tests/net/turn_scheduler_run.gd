extends SceneTree

## Exercises TurnScheduler both at its bus/transport boundary and across two
## sequentially booted Matches. Matches cannot coexist in one SceneTree: their
## simulation groups are tree-global, so each arm is torn down before the next.

const LegacyRulesFixture := preload("res://tests/support/legacy_rules_fixture.gd")
const ChecksumExchangeScript := preload("res://scripts/net/checksum_exchange.gd")
const LoopbackHubScript := preload("res://scripts/net/loopback_hub.gd")
const MatchFixtureScene := preload("res://tests/fixtures/match_fixture.tscn")
const RttTrackerScript := preload("res://scripts/net/rtt_tracker.gd")
const SimCommandBusScript := preload("res://scripts/sim/command_bus.gd")
const SimMoveCommandScript := preload("res://scripts/sim/commands/move_command.gd")
const TurnSchedulerScript := preload("res://scripts/net/turn_scheduler.gd")

const REPLAY_TICKS := 12
const SIM_GROUPS: Array[StringName] = [
	&"sim_units", &"sim_linger_effects", &"sim_projectiles", &"sim_buildings", &"sim_spice_mounds",
]

var _assertions := 0
var _failures := 0
var _current_case := ""
var _baseline_hash_a := 0
var _baseline_hash_b := 0


func _initialize() -> void:
	LegacyRulesFixture.install(root)
	_run_case("submit_local rejects a mismatched player_id", _test_rejects_mismatched_player_id)
	_run_case("a delivered local echo is discarded without resubmission", _test_discards_delivered_echo)
	_run_case("malformed frames are rejected with their distinct errors", _test_rejects_malformed_frames)
	_run_case("fixed delay and big-endian tick framing are independently pinned", _test_delay_and_wire_format)
	_run_case("checksum reports use their own big-endian frame layout", _test_checksum_report_wire_format)
	_run_case("pings use their own big-endian frame layout", _test_ping_wire_format)
	_run_case("a remote ping automatically receives a pong", _test_replies_to_remote_ping)
	_run_case("only a ping sender measures multi-peer pong replies", _test_routes_pongs_to_ping_sender)
	_run_case("a ping echo is discarded without sending a pong", _test_discards_ping_echo)
	_run_case("a remote pong reaches its wired RTT tracker", _test_delivers_remote_pong)
	_run_case("a pong echo is discarded without reaching its RTT tracker", _test_discards_pong_echo)
	_run_case("an unwired scheduler rejects pongs", _test_rejects_unwired_pong)
	_run_case("ping and pong frame failures are rejected with distinct errors", _test_rejects_ping_pong_frames)
	_run_case("a checksum echo is discarded without reaching its exchange", _test_discards_checksum_echo)
	_run_case("a remote checksum report reaches its wired exchange", _test_delivers_remote_checksum_report)
	_run_case("two remote checksum peers reach their wired exchange independently", _test_delivers_multiple_remote_checksum_reports)
	_run_case("checksum frame failures are rejected with distinct errors", _test_rejects_checksum_frames)
	_run_case("an unwired scheduler rejects checksum reports", _test_rejects_unwired_checksum_report)
	_run_case("remote activity starts unseen", _test_remote_activity_starts_unseen)
	_run_case("a remote command records activity", _test_remote_command_records_activity)
	_run_case("a remote checksum report records activity", _test_remote_checksum_report_records_activity)
	_run_case("remote pings and pongs record activity", _test_remote_ping_pong_records_activity)
	_run_case("an echo does not record remote activity", _test_echo_does_not_record_remote_activity)
	_run_case("remote activity retains the most recent receiving tick", _test_remote_activity_tracks_most_recent_tick)
	await _run_async_case("sequential matches agree after a transported command", _test_matching_hashes)
	await _run_async_case("a differing transported target stays equal per peer but changes the result", _test_differing_target_control)
	_finish("Turn scheduler tests")


func _run_case(case_name: String, test: Callable) -> void:
	_current_case = case_name
	var failures_before := _failures
	var assertions_before := _assertions
	test.call()
	_check_case_completed(case_name, failures_before, assertions_before)


func _run_async_case(case_name: String, test: Callable) -> void:
	_current_case = case_name
	var failures_before := _failures
	var assertions_before := _assertions
	await test.call()
	_check_case_completed(case_name, failures_before, assertions_before)


func _check_case_completed(case_name: String, failures_before: int, assertions_before: int) -> void:
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


func _finish(label: String) -> void:
	if _failures > 0:
		printerr("%s: %d failures after %d assertions" % [label, _failures, _assertions])
		quit(1)
		return
	print("%s: %d assertions passed" % [label, _assertions])
	quit(0)


func _make_move_command(
	player_id: int, entity_id := 1, target := Vector3(20.0, 0.0, 0.0)
) -> SimMoveCommand:
	var command: SimMoveCommand = SimMoveCommandScript.new()
	command.player_id = player_id
	command.entity_ids = PackedInt32Array([entity_id])
	command.target = target
	command.move_mode = 0
	return command


func _new_connected_endpoints() -> Dictionary:
	var hub := LoopbackHubScript.new()
	var endpoint_a = hub.add_endpoint(&"A")
	var endpoint_b = hub.add_endpoint(&"B")
	endpoint_a.open("")
	endpoint_b.open("")
	return {"hub": hub, "a": endpoint_a, "b": endpoint_b}


func _test_rejects_mismatched_player_id() -> void:
	var endpoints: Dictionary = _new_connected_endpoints()
	var bus := SimCommandBusScript.new()
	var scheduler = TurnSchedulerScript.new(bus, endpoints["a"], 1)
	var target := scheduler.submit_local(_make_move_command(2), 0)
	endpoints["hub"].step()
	_expect(target == -1, "a mismatched command must return the fail-closed sentinel")
	_expect(bus.pending_count() == 0, "a mismatched command must not enter the local bus")
	_expect(endpoints["b"].poll().is_empty(), "a mismatched command must not reach the peer")


func _test_discards_delivered_echo() -> void:
	var endpoints: Dictionary = _new_connected_endpoints()
	var bus := SimCommandBusScript.new()
	var scheduler = TurnSchedulerScript.new(bus, endpoints["a"], 1)
	scheduler.submit_local(_make_move_command(1), 0)
	endpoints["hub"].step()
	scheduler.advance_tick(0)
	_expect(scheduler.discarded_echo_count() == 1, "the delivered local echo must be counted and discarded")
	_expect(bus.pending_count() == 1, "discarding the echo must leave only the original local submission")


func _test_rejects_malformed_frames() -> void:
	var endpoints: Dictionary = _new_connected_endpoints()
	var bus := SimCommandBusScript.new()
	var scheduler = TurnSchedulerScript.new(bus, endpoints["a"], 1)

	endpoints["a"].receive(PackedByteArray())
	scheduler.advance_tick(0)
	_expect(bus.pending_count() == 0, "a discriminator-less frame must not enter the bus")
	_expect(scheduler.rejected_frame_count() == 1, "a discriminator-less frame must increment once")

	endpoints["a"].receive(PackedByteArray([0, 0]))
	scheduler.advance_tick(1)
	_expect(bus.pending_count() == 0, "a short command frame must not enter the bus")
	_expect(scheduler.rejected_frame_count() == 2, "a short command frame must increment once")

	var invalid_command_frame := StreamPeerBuffer.new()
	invalid_command_frame.big_endian = true
	invalid_command_frame.put_u8(0)
	invalid_command_frame.put_u32(0)
	invalid_command_frame.put_data(PackedByteArray([0, 0]))
	endpoints["a"].receive(invalid_command_frame.data_array)
	scheduler.advance_tick(2)
	_expect(bus.pending_count() == 0, "a codec-rejected frame must not enter the bus")
	_expect(scheduler.rejected_frame_count() == 3, "a codec-rejected frame must increment the rejection count once")
	_expect(
		scheduler.last_remote_activity_tick() == -1,
		"discriminator-less, short, and codec-rejected frames must not establish remote activity"
	)


func _test_delay_and_wire_format() -> void:
	var endpoints: Dictionary = _new_connected_endpoints()
	var bus_a := SimCommandBusScript.new()
	bus_a.input_delay_ticks = 2
	var scheduler_a = TurnSchedulerScript.new(bus_a, endpoints["a"], 1)
	var command: SimMoveCommand = _make_move_command(1)
	var target := scheduler_a.submit_local(command, 0)
	_expect(target == 2, "the first target must be the independently computed 0 + 2")
	_expect(bus_a.drain(0).is_empty(), "the local command must not drain at tick 0")
	_expect(bus_a.drain(1).is_empty(), "the local command must not drain at tick 1")
	var local_due := bus_a.drain(2)
	_expect(local_due.size() == 1 and local_due[0] == command, "the local command must drain at tick 2")

	endpoints["hub"].step()
	var frames: Array = endpoints["b"].poll()
	_expect(frames.size() == 1, "the peer must receive exactly the first submitted frame")
	if frames.is_empty():
		return
	var frame: PackedByteArray = frames[0]
	_expect(
		frame.size() >= 5
		and frame[0] == 0
		and frame[1] == 0
		and frame[2] == 0
		and frame[3] == 0
		and frame[4] == 2,
		"the command discriminator and outer tick prefix must have their exact big-endian layout"
	)

	var bus_b := SimCommandBusScript.new()
	var scheduler_b = TurnSchedulerScript.new(bus_b, endpoints["b"], 2)
	endpoints["b"].receive(frame)
	scheduler_b.advance_tick(0)
	_expect(bus_b.drain(1).is_empty(), "the remote command must not drain at tick 1")
	_expect(bus_b.drain(2).size() == 1, "the remote command must drain at the transmitted tick 2")
	_expect(
		scheduler_a.submit_local(_make_move_command(1), 5) == 7,
		"the second target must add the same delay to a different current tick"
	)


func _test_checksum_report_wire_format() -> void:
	var endpoints: Dictionary = _new_connected_endpoints()
	var scheduler = TurnSchedulerScript.new(SimCommandBusScript.new(), endpoints["a"], -2)
	scheduler.send_checksum_report(0x01020304, 0xa1b2c3d4)
	endpoints["hub"].step()
	var frames: Array = endpoints["b"].poll()
	_expect(frames.size() == 1, "the peer must receive exactly one checksum report")
	if frames.is_empty():
		return
	var frame: PackedByteArray = frames[0]
	_expect(
		frame == PackedByteArray([1, 1, 2, 3, 4, 255, 255, 255, 254, 161, 178, 195, 212]),
		"a checksum report must be discriminator, u32 tick, s32 sender, then u32 hash in big-endian order"
	)


func _test_ping_wire_format() -> void:
	var endpoints: Dictionary = _new_connected_endpoints()
	var scheduler = TurnSchedulerScript.new(SimCommandBusScript.new(), endpoints["a"], -2)
	scheduler.send_ping(0x01020304)
	endpoints["hub"].step()
	var frames: Array = endpoints["b"].poll()
	_expect(frames.size() == 1, "the peer must receive exactly one ping")
	if frames.is_empty():
		return
	_expect(
		frames[0] == PackedByteArray([2, 1, 2, 3, 4, 255, 255, 255, 254]),
		"a ping must be discriminator, u32 tick, then s32 sender in big-endian order"
	)


func _test_replies_to_remote_ping() -> void:
	var endpoints: Dictionary = _new_connected_endpoints()
	var scheduler_a = TurnSchedulerScript.new(SimCommandBusScript.new(), endpoints["a"], 1)
	var scheduler_b = TurnSchedulerScript.new(SimCommandBusScript.new(), endpoints["b"], 2)
	scheduler_a.send_ping(4)
	endpoints["hub"].step()
	scheduler_a.advance_tick(0)
	scheduler_b.advance_tick(0)
	endpoints["hub"].step()
	var frames: Array = endpoints["a"].poll()
	_expect(frames.size() == 1, "the original sender must receive exactly one automatic pong")
	if frames.is_empty():
		return
	_expect(
		frames[0] == PackedByteArray([3, 0, 0, 0, 4, 0, 0, 0, 1, 0, 0, 0, 2]),
		"the pong must preserve the ping tick, identify its sender, and identify the replying peer"
	)


func _test_routes_pongs_to_ping_sender() -> void:
	var hub = LoopbackHubScript.new()
	var endpoint_a = hub.add_endpoint(&"A")
	var endpoint_b = hub.add_endpoint(&"B")
	var endpoint_c = hub.add_endpoint(&"C")
	endpoint_a.open("")
	endpoint_b.open("")
	endpoint_c.open("")
	var tracker_a = RttTrackerScript.new()
	var tracker_b = RttTrackerScript.new()
	var tracker_c = RttTrackerScript.new()
	var scheduler_a = TurnSchedulerScript.new(SimCommandBusScript.new(), endpoint_a, 1, null, tracker_a)
	var scheduler_b = TurnSchedulerScript.new(SimCommandBusScript.new(), endpoint_b, 2, null, tracker_b)
	var scheduler_c = TurnSchedulerScript.new(SimCommandBusScript.new(), endpoint_c, 3, null, tracker_c)

	scheduler_a.send_ping(4)
	hub.step()
	scheduler_a.advance_tick(5)
	scheduler_b.advance_tick(5)
	scheduler_c.advance_tick(5)
	hub.step()
	scheduler_a.advance_tick(10)
	scheduler_b.advance_tick(10)
	scheduler_c.advance_tick(10)

	_expect(tracker_a.rtt_ticks_for(2) == 6, "the ping sender must measure B's reply")
	_expect(tracker_a.rtt_ticks_for(3) == 6, "the ping sender must measure C's reply")
	_expect(tracker_a.known_peer_count() == 2, "the ping sender must track both responders independently")
	_expect(tracker_b.known_peer_count() == 0, "B must not measure C's pong to A")
	_expect(tracker_c.known_peer_count() == 0, "C must not measure B's pong to A")
	_expect(scheduler_b.rejected_frame_count() == 0, "B must ignore C's pong to A without rejecting it")
	_expect(scheduler_c.rejected_frame_count() == 0, "C must ignore B's pong to A without rejecting it")
	_expect(scheduler_b.last_remote_activity_tick() == 10, "B must record C's valid pong to A as activity")
	_expect(scheduler_c.last_remote_activity_tick() == 10, "C must record B's valid pong to A as activity")


func _test_discards_ping_echo() -> void:
	var endpoints: Dictionary = _new_connected_endpoints()
	var scheduler = TurnSchedulerScript.new(SimCommandBusScript.new(), endpoints["a"], 1)
	endpoints["a"].receive(PackedByteArray([2, 0, 0, 0, 4, 0, 0, 0, 1]))
	scheduler.advance_tick(0)
	_expect(scheduler.discarded_echo_count() == 1, "a local ping echo must be counted and discarded")
	_expect(endpoints["a"].poll().is_empty(), "a local ping echo must not trigger a self-pong")


func _test_delivers_remote_pong() -> void:
	var endpoints: Dictionary = _new_connected_endpoints()
	var tracker = RttTrackerScript.new()
	var scheduler = TurnSchedulerScript.new(SimCommandBusScript.new(), endpoints["a"], 1, null, tracker)
	endpoints["a"].receive(PackedByteArray([3, 0, 0, 0, 3, 0, 0, 0, 1, 0, 0, 0, 2]))
	scheduler.advance_tick(10)
	_expect(tracker.rtt_ticks_for(2) == 7, "the tracker must receive the exact processed tick minus ping tick")


func _test_discards_pong_echo() -> void:
	var endpoints: Dictionary = _new_connected_endpoints()
	var tracker = RttTrackerScript.new()
	var scheduler = TurnSchedulerScript.new(SimCommandBusScript.new(), endpoints["a"], 1, null, tracker)
	endpoints["a"].receive(PackedByteArray([3, 0, 0, 0, 3, 0, 0, 0, 1, 0, 0, 0, 1]))
	scheduler.advance_tick(10)
	_expect(scheduler.discarded_echo_count() == 1, "a local pong echo must be counted and discarded")
	_expect(tracker.known_peer_count() == 0, "a local pong echo must not reach the tracker")


func _test_rejects_unwired_pong() -> void:
	var endpoints: Dictionary = _new_connected_endpoints()
	var scheduler = TurnSchedulerScript.new(SimCommandBusScript.new(), endpoints["a"], 1)
	endpoints["a"].receive(PackedByteArray([3, 0, 0, 0, 3, 0, 0, 0, 1, 0, 0, 0, 2]))
	scheduler.advance_tick(10)
	_expect(scheduler.rejected_frame_count() == 1, "an unwired pong must increment the rejection count")


func _test_rejects_ping_pong_frames() -> void:
	var endpoints: Dictionary = _new_connected_endpoints()
	var scheduler = TurnSchedulerScript.new(SimCommandBusScript.new(), endpoints["a"], 1)

	endpoints["a"].receive(PackedByteArray([2, 0, 0]))
	scheduler.advance_tick(0)
	_expect(scheduler.rejected_frame_count() == 1, "a short ping must increment once")

	endpoints["a"].receive(PackedByteArray([3, 0, 0]))
	scheduler.advance_tick(1)
	_expect(scheduler.rejected_frame_count() == 2, "a short pong must increment once")


func _test_discards_checksum_echo() -> void:
	var endpoints: Dictionary = _new_connected_endpoints()
	var exchange = ChecksumExchangeScript.new()
	var scheduler = TurnSchedulerScript.new(SimCommandBusScript.new(), endpoints["a"], 1, exchange)
	scheduler.send_checksum_report(4, 100)
	endpoints["hub"].step()
	scheduler.advance_tick(0)
	_expect(scheduler.discarded_echo_count() == 1, "a local checksum echo must be counted and discarded")
	_expect(exchange.pending_remote_count() == 0, "a local checksum echo must not reach the exchange")


func _test_delivers_remote_checksum_report() -> void:
	var endpoints: Dictionary = _new_connected_endpoints()
	var exchange = ChecksumExchangeScript.new()
	exchange.record_local_hash(7, 1234)
	var scheduler_a = TurnSchedulerScript.new(SimCommandBusScript.new(), endpoints["a"], 1, exchange)
	var scheduler_b = TurnSchedulerScript.new(SimCommandBusScript.new(), endpoints["b"], 2)
	scheduler_b.send_checksum_report(7, 1234)
	endpoints["hub"].step()
	scheduler_a.advance_tick(0)
	_expect(exchange.agreement_count() == 1, "a remote report must resolve against the matching local hash")
	_expect(exchange.pending_remote_count() == 0, "a resolved remote report must not remain pending")


func _test_delivers_multiple_remote_checksum_reports() -> void:
	var hub = LoopbackHubScript.new()
	var endpoint_a = hub.add_endpoint(&"A")
	var endpoint_b = hub.add_endpoint(&"B")
	var endpoint_c = hub.add_endpoint(&"C")
	endpoint_a.open("")
	endpoint_b.open("")
	endpoint_c.open("")
	var exchange = ChecksumExchangeScript.new()
	exchange.record_local_hash(7, 100)
	var scheduler_a = TurnSchedulerScript.new(SimCommandBusScript.new(), endpoint_a, 1, exchange)
	var scheduler_b = TurnSchedulerScript.new(SimCommandBusScript.new(), endpoint_b, 2)
	var scheduler_c = TurnSchedulerScript.new(SimCommandBusScript.new(), endpoint_c, 3)
	scheduler_b.send_checksum_report(7, 100)
	scheduler_c.send_checksum_report(7, 999)
	hub.step()
	scheduler_a.advance_tick(0)
	_expect(exchange.agreement_count() == 1, "the matching remote peer must reach the exchange")
	_expect(exchange.mismatch_count() == 1, "the differing remote peer must reach the exchange")
	_expect(
		exchange.last_mismatch()["sender_player_id"] == 3,
		"the wired exchange must retain the specific disagreeing sender"
	)


func _test_rejects_checksum_frames() -> void:
	var endpoints: Dictionary = _new_connected_endpoints()
	var scheduler = TurnSchedulerScript.new(SimCommandBusScript.new(), endpoints["a"], 1)

	endpoints["a"].receive(PackedByteArray([4]))
	scheduler.advance_tick(0)
	_expect(scheduler.rejected_frame_count() == 1, "an unknown discriminator must increment once")

	endpoints["a"].receive(PackedByteArray([1, 0, 0]))
	scheduler.advance_tick(1)
	_expect(scheduler.rejected_frame_count() == 2, "a short checksum report must increment once")


func _test_rejects_unwired_checksum_report() -> void:
	var endpoints: Dictionary = _new_connected_endpoints()
	var scheduler_a = TurnSchedulerScript.new(SimCommandBusScript.new(), endpoints["a"], 1)
	var scheduler_b = TurnSchedulerScript.new(SimCommandBusScript.new(), endpoints["b"], 2)
	scheduler_b.send_checksum_report(8, 200)
	endpoints["hub"].step()
	scheduler_a.advance_tick(0)
	_expect(scheduler_a.rejected_frame_count() == 1, "an unwired checksum report must be rejected")
	_expect(
		scheduler_a.last_remote_activity_tick() == 0,
		"an unwired checksum report must establish remote activity before routing rejects it"
	)


func _test_remote_activity_starts_unseen() -> void:
	var endpoints: Dictionary = _new_connected_endpoints()
	var scheduler = TurnSchedulerScript.new(SimCommandBusScript.new(), endpoints["a"], 1)
	_expect(scheduler.last_remote_activity_tick() == -1, "a scheduler must start with no remote activity")


func _test_remote_command_records_activity() -> void:
	var endpoints: Dictionary = _new_connected_endpoints()
	var scheduler_a = TurnSchedulerScript.new(SimCommandBusScript.new(), endpoints["a"], 1)
	var scheduler_b = TurnSchedulerScript.new(SimCommandBusScript.new(), endpoints["b"], 2)
	scheduler_b.submit_local(_make_move_command(2), 0)
	endpoints["hub"].step()
	scheduler_a.advance_tick(7)
	_expect(
		scheduler_a.last_remote_activity_tick() == 7,
		"a successfully decoded remote command must record the receiving tick"
	)


func _test_remote_checksum_report_records_activity() -> void:
	var endpoints: Dictionary = _new_connected_endpoints()
	var exchange = ChecksumExchangeScript.new()
	var scheduler_a = TurnSchedulerScript.new(SimCommandBusScript.new(), endpoints["a"], 1, exchange)
	var scheduler_b = TurnSchedulerScript.new(SimCommandBusScript.new(), endpoints["b"], 2)
	scheduler_b.send_checksum_report(4, 100)
	endpoints["hub"].step()
	scheduler_a.advance_tick(8)
	_expect(
		scheduler_a.last_remote_activity_tick() == 8,
		"a successfully decoded remote checksum report must record the receiving tick"
	)


func _test_remote_ping_pong_records_activity() -> void:
	var endpoints: Dictionary = _new_connected_endpoints()
	var tracker = RttTrackerScript.new()
	var scheduler = TurnSchedulerScript.new(SimCommandBusScript.new(), endpoints["a"], 1, null, tracker)
	endpoints["a"].receive(PackedByteArray([2, 0, 0, 0, 4, 0, 0, 0, 2]))
	scheduler.advance_tick(6)
	_expect(scheduler.last_remote_activity_tick() == 6, "a remote ping must record the receiving tick")

	endpoints["a"].receive(PackedByteArray([3, 0, 0, 0, 4, 0, 0, 0, 1, 0, 0, 0, 2]))
	scheduler.advance_tick(9)
	_expect(scheduler.last_remote_activity_tick() == 9, "a remote pong must record the receiving tick")


func _test_echo_does_not_record_remote_activity() -> void:
	var endpoints: Dictionary = _new_connected_endpoints()
	var scheduler_a = TurnSchedulerScript.new(SimCommandBusScript.new(), endpoints["a"], 1)
	var scheduler_b = TurnSchedulerScript.new(SimCommandBusScript.new(), endpoints["b"], 2)
	scheduler_b.submit_local(_make_move_command(2), 0)
	endpoints["hub"].step()
	scheduler_a.advance_tick(5)
	scheduler_a.submit_local(_make_move_command(1), 0)
	endpoints["hub"].step()
	scheduler_a.advance_tick(6)
	_expect(
		scheduler_a.last_remote_activity_tick() == 5,
		"a local command echo must leave the preceding remote activity tick unchanged"
	)


func _test_remote_activity_tracks_most_recent_tick() -> void:
	var endpoints: Dictionary = _new_connected_endpoints()
	var scheduler_a = TurnSchedulerScript.new(SimCommandBusScript.new(), endpoints["a"], 1)
	var scheduler_b = TurnSchedulerScript.new(SimCommandBusScript.new(), endpoints["b"], 2)
	scheduler_b.submit_local(_make_move_command(2), 0)
	endpoints["hub"].step()
	scheduler_a.advance_tick(2)
	scheduler_b.submit_local(_make_move_command(2), 1)
	endpoints["hub"].step()
	scheduler_a.advance_tick(9)
	scheduler_a.advance_tick(10)
	_expect(
		scheduler_a.last_remote_activity_tick() == 9,
		"the latest real frame must replace the prior tick and remain after an empty poll"
	)


func _test_matching_hashes() -> void:
	var result := await _run_pair(Vector3(20.0, 0.0, 0.0))
	_baseline_hash_a = int(result["hash_a"])
	_baseline_hash_b = int(result["hash_b"])
	_expect(bool(result["moved_a"]) and bool(result["moved_b"]), "the transported move must affect both matches")
	_expect(_baseline_hash_a == _baseline_hash_b, "the two independently booted matches must hash equally")
	_expect(
		int(result["agreements_a"]) == REPLAY_TICKS,
		"client A must agree with every checksum report from client B"
	)
	_expect(
		int(result["agreements_b"]) == REPLAY_TICKS,
		"client B must agree with every checksum report from client A"
	)
	_expect(int(result["mismatches_a"]) == 0, "client A must not record a checksum mismatch")
	_expect(int(result["mismatches_b"]) == 0, "client B must not record a checksum mismatch")
	_expect(int(result["pending_a"]) == 0, "client A must resolve every received checksum report")
	_expect(int(result["pending_b"]) == 0, "client B must resolve every received checksum report")
	_expect(
		int(result["last_remote_activity_tick_b"]) == int(result["final_remote_report_poll_tick_b"]),
		"client B must record the tick that polled client A's final checksum report"
	)
	_expect(
		int(result["last_remote_activity_tick_a"]) == int(result["final_local_tick_a"]),
		"client A must record its captured final tick when it polls client B after teardown"
	)


func _test_differing_target_control() -> void:
	var result := await _run_pair(Vector3(40.0, 0.0, 0.0))
	var control_hash_a := int(result["hash_a"])
	var control_hash_b := int(result["hash_b"])
	_expect(control_hash_a == control_hash_b, "the differing-target clients must still agree with each other")
	_expect(control_hash_a != _baseline_hash_a, "the differing target must produce a different final hash")
	_expect(
		bool(result["moved_a"]) and bool(result["moved_b"]),
		"the differing transported move must affect both matches"
	)
	print(
		"TURN_SCHEDULER_RUN_RESULT baseline_hash_a=%d baseline_hash_b=%d control_hash_a=%d control_hash_b=%d"
		% [_baseline_hash_a, _baseline_hash_b, control_hash_a, control_hash_b]
	)


func _run_pair(move_offset: Vector3) -> Dictionary:
	var hub := LoopbackHubScript.new()
	var endpoint_a = hub.add_endpoint(&"A")
	var endpoint_b = hub.add_endpoint(&"B")
	endpoint_a.open("")
	endpoint_b.open("")

	var match_a = await _boot_arm()
	var scout_a = match_a.get_node("Units/ScoutA")
	var start_a: Vector3 = scout_a.simulation_position()
	match_a.command_bus().input_delay_ticks = 2
	var checksum_exchange_a = ChecksumExchangeScript.new()
	var scheduler_a = TurnSchedulerScript.new(match_a.command_bus(), endpoint_a, 1, checksum_exchange_a)
	var final_local_tick_a := 0
	for tick in REPLAY_TICKS:
		if tick == 0:
			scheduler_a.submit_local(
				_make_move_command(scout_a.owner_player_id, scout_a.entity_id, start_a + move_offset),
				match_a.next_orderable_tick()
			)
		hub.step()
		var poll_tick_a: int = match_a.current_tick()
		scheduler_a.advance_tick(poll_tick_a)
		var executed_tick: int = match_a.advance_ticks(1)
		final_local_tick_a = executed_tick
		var hash_now: int = int(match_a.entity_state().state_hash())
		checksum_exchange_a.record_local_hash(executed_tick, hash_now)
		scheduler_a.send_checksum_report(executed_tick, hash_now)
	for _flush in 4:
		hub.step()
	var hash_a: int = int(match_a.entity_state().state_hash())
	var moved_a: bool = not scout_a.simulation_position().is_equal_approx(start_a)
	await _teardown_arm(match_a)

	var match_b = await _boot_arm()
	var scout_b = match_b.get_node("Units/ScoutA")
	var start_b: Vector3 = scout_b.simulation_position()
	match_b.command_bus().input_delay_ticks = 2
	var checksum_exchange_b = ChecksumExchangeScript.new()
	var scheduler_b = TurnSchedulerScript.new(match_b.command_bus(), endpoint_b, 2, checksum_exchange_b)
	var final_remote_report_poll_tick_b := -1
	for _tick in REPLAY_TICKS:
		hub.step()
		var poll_tick_b: int = match_b.current_tick()
		var pending_before := checksum_exchange_b.pending_remote_count()
		scheduler_b.advance_tick(poll_tick_b)
		if checksum_exchange_b.pending_remote_count() > pending_before:
			final_remote_report_poll_tick_b = poll_tick_b
		var executed_tick: int = match_b.advance_ticks(1)
		var hash_now: int = int(match_b.entity_state().state_hash())
		checksum_exchange_b.record_local_hash(executed_tick, hash_now)
		scheduler_b.send_checksum_report(executed_tick, hash_now)
	for _flush in 4:
		hub.step()
	scheduler_a.advance_tick(final_local_tick_a)
	var hash_b: int = int(match_b.entity_state().state_hash())
	var moved_b: bool = not scout_b.simulation_position().is_equal_approx(start_b)
	await _teardown_arm(match_b)
	return {
		"hash_a": hash_a,
		"hash_b": hash_b,
		"moved_a": moved_a,
		"moved_b": moved_b,
		"agreements_a": checksum_exchange_a.agreement_count(),
		"agreements_b": checksum_exchange_b.agreement_count(),
		"mismatches_a": checksum_exchange_a.mismatch_count(),
		"mismatches_b": checksum_exchange_b.mismatch_count(),
		"pending_a": checksum_exchange_a.pending_remote_count(),
		"pending_b": checksum_exchange_b.pending_remote_count(),
		"last_remote_activity_tick_a": scheduler_a.last_remote_activity_tick(),
		"last_remote_activity_tick_b": scheduler_b.last_remote_activity_tick(),
		"final_local_tick_a": final_local_tick_a,
		"final_remote_report_poll_tick_b": final_remote_report_poll_tick_b,
	}


func _boot_arm():
	var match_instance := MatchFixtureScene.instantiate()
	root.add_child(match_instance)
	match_instance.set_process(false)
	await process_frame
	match_instance.set_process(false)
	await process_frame
	match_instance.set_process(false)
	return match_instance


func _teardown_arm(match_instance) -> void:
	match_instance.queue_free()
	await process_frame
	await process_frame
	for group_name in SIM_GROUPS:
		_expect(get_nodes_in_group(group_name).is_empty(), "teardown must leave %s empty before the next arm" % group_name)
