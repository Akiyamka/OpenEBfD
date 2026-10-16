extends "res://tests/support/suite.gd"

const ChecksumExchangeScript := preload("res://scripts/net/checksum_exchange.gd")
const LegacyRulesFixture := preload("res://tests/support/legacy_rules_fixture.gd")
const LoopbackHubScript := preload("res://scripts/net/loopback_hub.gd")
const MatchFixtureScene := preload("res://tests/fixtures/websocket_match_fixture.tscn")
const SimCommandBusScript := preload("res://scripts/sim/command_bus.gd")
const TurnSchedulerScript := preload("res://scripts/net/turn_scheduler.gd")

const SIM_GROUPS: Array[StringName] = [
	&"sim_units", &"sim_linger_effects", &"sim_projectiles", &"sim_buildings", &"sim_spice_mounds",
]


func _initialize() -> void:
	LegacyRulesFixture.install(root)
	await _run_async_case("a gathered match runs no tick its peer has not covered", _test_gate_blocks_match)
	await _run_async_case("the frame loop polls the gate in wall-clock time", _test_process_polls_gate)
	await _run_async_case("plain rooms announce nothing and never wait", _test_plain_rooms_are_unarmed)
	await _run_async_case("a long wait is shown and a silent peer is named at the threshold", _test_wait_status_and_stall)
	await _run_async_case("a held match compares a lagging peer's report and halts while waiting", _test_halts_while_waiting)
	await _run_async_case("a peer heard while still behind is waited on again, not unresponsive", _test_wait_status_downgrades)
	_finish("Match turn barrier tests")


func _boot_arm(player_count := 2, room_url := "ws://test/room") -> Dictionary:
	var hub := LoopbackHubScript.new()
	var endpoint = hub.add_endpoint(&"match")
	var match_instance = MatchFixtureScene.instantiate()
	match_instance.local_player_id_for_test = 1
	match_instance.net_room_url_for_test = room_url
	match_instance.net_player_count_for_test = player_count
	match_instance.transport_override = endpoint
	root.add_child(match_instance)
	match_instance.set_process(false)
	await process_frame
	match_instance.set_process(false)
	await process_frame
	match_instance.set_process(false)
	return {"hub": hub, "endpoint": endpoint, "match": match_instance}


func _new_peer(hub) -> TurnScheduler:
	var endpoint = hub.add_endpoint(&"peer2")
	endpoint.open("")
	var bus := SimCommandBusScript.new()
	bus.input_delay_ticks = 2
	var peer = TurnSchedulerScript.new(bus, endpoint, 2, ChecksumExchangeScript.new())
	peer.begin_gathering(2, 320)
	peer.begin_turn_barrier(2, 320)
	return peer


func _release_directly(match_instance, hub, peer) -> void:
	for now_msec in [0, 20, 40, 320, 340, 360]:
		match_instance.turn_scheduler().poll_gathering(now_msec)
		peer.poll_gathering(now_msec)
		hub.step()


func _release_and_sync(match_instance, hub, peer) -> void:
	_release_directly(match_instance, hub, peer)
	hub.step()
	match_instance._poll_turn_barrier(400)
	peer.poll_turn_barrier(1, 400)


func _test_gate_blocks_match() -> void:
	var arm := await _boot_arm()
	var match_instance = arm["match"]
	var peer = _new_peer(arm["hub"])
	_release_and_sync(match_instance, arm["hub"], peer)
	_expect(match_instance.advance_ticks(10) == 2, "the gathered match must stop at the peer's release horizon")
	arm["hub"].step()
	peer.poll_turn_barrier(1, 500)
	_expect(peer.known_horizon_for(1) == 4, "the peer must receive horizons after ticks one and two")
	peer.announce_horizon(5)
	arm["hub"].step()
	match_instance._poll_turn_barrier(520)
	_expect(match_instance.advance_ticks(10) == 7, "a later peer horizon must release the matching ticks")
	await _teardown_arm(match_instance)


func _test_process_polls_gate() -> void:
	var arm := await _boot_arm()
	var match_instance = arm["match"]
	var hub = arm["hub"]
	var peer = _new_peer(hub)
	_release_directly(match_instance, hub, peer)
	match_instance.set_process(true)
	var deadline := Time.get_ticks_msec() + 1000
	while match_instance.current_tick() < 2 and Time.get_ticks_msec() < deadline:
		hub.step()
		await process_frame
	var hold_until := Time.get_ticks_msec() + 400
	while Time.get_ticks_msec() < hold_until:
		hub.step()
		await process_frame
	_expect(match_instance.current_tick() == 2, "the process loop must remain held without a peer horizon")
	peer.announce_horizon(6)
	deadline = Time.get_ticks_msec() + 1000
	while match_instance.current_tick() < 8 and Time.get_ticks_msec() < deadline:
		hub.step()
		await process_frame
	_expect(match_instance.current_tick() == 8, "the frame-loop poll must receive the releasing horizon")
	await _teardown_arm(match_instance)


func _test_plain_rooms_are_unarmed() -> void:
	var arm_a := await _boot_arm(0)
	var probe_a = arm_a["hub"].add_endpoint(&"probe")
	probe_a.open("")
	_expect(arm_a["match"].advance_ticks(100) == 100, "a plain room must remain free-running")
	arm_a["hub"].step()
	var frames_a: Array = probe_a.poll()
	_expect(not frames_a.is_empty(), "the plain room's existing scheduler traffic must remain live")
	var horizons_a := false
	for frame in frames_a:
		horizons_a = horizons_a or frame[0] == 6
	_expect(not horizons_a, "a plain room must not send horizon frames")
	await _teardown_arm(arm_a["match"])
	var arm_b := await _boot_arm(1)
	var probe_b = arm_b["hub"].add_endpoint(&"probe")
	probe_b.open("")
	_expect(arm_b["match"].advance_ticks(100) == 100, "a one-player room must remain free-running")
	arm_b["hub"].step()
	var horizons_b := false
	for frame in probe_b.poll():
		horizons_b = horizons_b or frame[0] == 6
	_expect(not horizons_b, "a one-player room must not send horizon frames")
	await _teardown_arm(arm_b["match"])


func _test_wait_status_and_stall() -> void:
	var arm := await _boot_arm()
	var match_instance = arm["match"]
	var peer = _new_peer(arm["hub"])
	_release_and_sync(match_instance, arm["hub"], peer)
	match_instance.advance_ticks(10)
	match_instance._poll_turn_barrier(1000)
	match_instance._poll_turn_barrier(1319)
	_expect(not "Waiting for player 2" in match_instance.selection_label.text, "a short wait must not be shown")
	match_instance._poll_turn_barrier(1320)
	_expect("Waiting for player 2" in match_instance.selection_label.text, "a full cadence wait must be shown")
	_expect(match_instance.turn_scheduler().waiting_player_ids() == [2], "the scheduler must expose the waiting peer")
	match_instance._poll_turn_barrier(4200)
	_expect(not match_instance.is_player_stalled(2), "the exact silence threshold must not stall")
	match_instance._poll_turn_barrier(4201)
	_expect(match_instance.is_player_stalled(2), "silence beyond the threshold must stall")
	_expect(match_instance.stalled_player_ids() == [2], "the stalled roster must name the peer")
	_expect("Player 2 is not responding" in match_instance.selection_label.text, "the status line must name the unresponsive peer")
	peer.announce_horizon(6)
	arm["hub"].step()
	match_instance._poll_turn_barrier(4300)
	_expect(not match_instance.is_player_stalled(2), "a covering horizon must clear the stall")
	_expect(not "Waiting for player 2" in match_instance.selection_label.text and not "is not responding" in match_instance.selection_label.text, "resuming must restore the ordinary label")
	_expect(match_instance.advance_ticks(10) == 8, "the peer's horizon must release ticks through eight")
	await _teardown_arm(match_instance)


func _test_halts_while_waiting() -> void:
	var arm := await _boot_arm()
	var match_instance = arm["match"]
	var peer = _new_peer(arm["hub"])
	_release_and_sync(match_instance, arm["hub"], peer)
	peer.announce_horizon(8)
	arm["hub"].step()
	match_instance._poll_turn_barrier(420)
	_expect(match_instance.advance_ticks(100) == 10, "the peer horizon must allow the match through tick ten")
	var wrong := int(match_instance.checksum_exchange()._local_hash_by_tick.get(8, 0)) ^ 1
	peer.send_checksum_report(8, wrong)
	arm["hub"].step()
	match_instance._poll_turn_barrier(440)
	_expect(match_instance.is_halted(), "a mismatch received while gated must halt immediately")
	_expect(match_instance.halted_at_tick() == 10, "the held match must halt at its last executed tick")
	_expect(match_instance.checksum_exchange().mismatch_count() == 1, "the report must be compared once")
	_expect(match_instance.checksum_exchange().dropped_stale_report_count() == 0, "the held report must not be stale")
	_expect(match_instance.halt_dump().size() > 0 and match_instance.halt_dump()[0].begins_with("[desync] player 1 halted at tick 10"), "the halt dump must retain V1's first line")
	match_instance._poll_turn_barrier(10000)
	match_instance._poll_turn_barrier(20000)
	_expect(not "Waiting for player 2" in match_instance.selection_label.text and not "is not responding" in match_instance.selection_label.text, "a halted match must not show turn wait state")
	_expect(match_instance.turn_scheduler().turn_wait_msec() == 0, "a halted match must stop polling the scheduler")
	await _teardown_arm(match_instance)


func _test_wait_status_downgrades() -> void:
	var arm := await _boot_arm()
	var match_instance = arm["match"]
	var peer = _new_peer(arm["hub"])
	_release_and_sync(match_instance, arm["hub"], peer)
	match_instance.advance_ticks(10)
	match_instance._poll_turn_barrier(1000)
	match_instance._poll_turn_barrier(1320)
	match_instance._poll_turn_barrier(4201)
	_expect("Player 2 is not responding" in match_instance.selection_label.text, "the precondition must show an unresponsive peer")
	peer.announce_horizon(0)
	arm["hub"].step()
	match_instance._poll_turn_barrier(4300)
	_expect(match_instance.turn_scheduler().waiting_player_ids() == [2], "an insufficient horizon must keep the match gated")
	_expect(not match_instance.is_player_stalled(2), "hearing a peer must clear its silence verdict")
	_expect("Waiting for player 2" in match_instance.selection_label.text and not "is not responding" in match_instance.selection_label.text, "a heard but behind peer must downgrade to waiting")
	match_instance._poll_turn_barrier(7500)
	match_instance._poll_turn_barrier(7501)
	_expect("Player 2 is not responding" in match_instance.selection_label.text, "a second silence in one wait must be reported")
	await _teardown_arm(match_instance)


func _teardown_arm(match_instance) -> void:
	match_instance.queue_free()
	await process_frame
	await process_frame
	for group_name in SIM_GROUPS:
		_expect(get_nodes_in_group(group_name).is_empty(), "teardown must leave %s empty before the next arm" % group_name)
