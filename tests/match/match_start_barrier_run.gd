extends "res://tests/support/suite.gd"

const LegacyRulesFixture := preload("res://tests/support/legacy_rules_fixture.gd")
const ChecksumExchangeScript := preload("res://scripts/net/checksum_exchange.gd")
const LoopbackHubScript := preload("res://scripts/net/loopback_hub.gd")
const MatchFixtureScene := preload("res://tests/fixtures/websocket_match_fixture.tscn")
const MatchScript := preload("res://scripts/match/match.gd")
const SimCommandBusScript := preload("res://scripts/sim/command_bus.gd")
const TurnSchedulerScript := preload("res://scripts/net/turn_scheduler.gd")

const SIM_GROUPS: Array[StringName] = [
	&"sim_units", &"sim_linger_effects", &"sim_projectiles", &"sim_buildings", &"sim_spice_mounds",
]


func _initialize() -> void:
	LegacyRulesFixture.install(root)
	await _run_async_case("a gathering match cannot advance directly", _test_wait_blocks_direct_ticks)
	await _run_async_case("the match loop waits then starts on START", _test_match_loop_waits_then_starts)
	await _run_async_case("barrier delay seed leaves ordinary rooms unchanged", _test_delay_seed_and_plain_room)
	await _run_async_case("a floor measurement is not a delay change", _test_floor_measurement_is_not_change)
	await _run_async_case("a count without a room does not wait", _test_count_without_room)
	await _run_async_case("one player with a room behaves as no flag", _test_one_player_is_no_barrier)
	_finish("Match start barrier tests")


func _boot_arm(player_count := 0, room_url := "", with_transport := true) -> Dictionary:
	var hub := LoopbackHubScript.new()
	var endpoint = hub.add_endpoint(&"match") if with_transport else null
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


func _new_peer(hub) -> Dictionary:
	var endpoint = hub.add_endpoint(&"peer2")
	endpoint.open("")
	var bus := SimCommandBusScript.new()
	bus.input_delay_ticks = 2
	var peer = TurnSchedulerScript.new(bus, endpoint, 2, ChecksumExchangeScript.new())
	peer.begin_gathering(2, 320)
	peer.begin_turn_barrier(2, 320)
	return {"endpoint": endpoint, "bus": bus, "peer": peer}


func _release_directly(match_instance, hub, peer) -> void:
	for now_msec in [0, 20, 40, 320, 340, 360]:
		match_instance.turn_scheduler().poll_gathering(now_msec)
		peer.poll_gathering(now_msec)
		hub.step()


func _test_wait_blocks_direct_ticks() -> void:
	var arm := await _boot_arm(2, "ws://test/room")
	var match_instance = arm["match"]
	_expect(match_instance.advance_ticks(10) == 0, "a gathering match must not advance through the public tick API")
	_expect(match_instance.current_tick() == 0, "the frozen barrier must keep the match at tick zero")
	_expect(match_instance.is_waiting_for_players(), "the barrier must be visible through Match")
	await _teardown_arm(match_instance)


func _test_match_loop_waits_then_starts() -> void:
	var arm := await _boot_arm(2, "ws://test/room")
	var match_instance = arm["match"]
	var hub = arm["hub"]
	match_instance.set_process(true)
	var deadline := Time.get_ticks_msec() + 500
	while match_instance.turn_scheduler().present_player_count() < 1 and Time.get_ticks_msec() < deadline:
		hub.step()
		await process_frame
	for _i in 20:
		hub.step()
		await process_frame
	_expect(match_instance.current_tick() == 0, "the process loop must not tick while waiting")
	_expect(match_instance.turn_scheduler().present_player_count() == 1, "the match must observe only its echoed hello before the peer opens")
	_expect("Waiting for players: 1 of 2 present" in match_instance.selection_label.text, "the waiting count must reach the visible status")
	var peer_data := _new_peer(hub)
	deadline = Time.get_ticks_msec() + 1000
	while match_instance.is_waiting_for_players() and Time.get_ticks_msec() < deadline:
		hub.step()
		peer_data["peer"].poll_gathering(Time.get_ticks_msec())
		await process_frame
	_expect(not match_instance.is_waiting_for_players(), "the match loop must release after both peers gather")
	_expect(not peer_data["peer"].is_gathering(), "the raw peer must release on the same START")
	deadline = Time.get_ticks_msec() + 500
	while match_instance.current_tick() == 0 and Time.get_ticks_msec() < deadline:
		hub.step()
		await process_frame
	_expect(match_instance.current_tick() > 0, "ticks must begin on a frame after release")
	_expect("match started" in match_instance.selection_label.text, "release must replace the waiting status")
	await _teardown_arm(match_instance)


func _test_delay_seed_and_plain_room() -> void:
	var barrier_arm := await _boot_arm(2, "ws://test/room")
	var barrier_match = barrier_arm["match"]
	_expect(barrier_match.command_bus().input_delay_ticks == 2, "a gathered match must begin at the delay floor")
	_expect(barrier_match.input_delay_change_count() == 0, "the initial floor is a seed, not a change event")
	_expect(barrier_match.turn_scheduler()._hello_interval_msec == 320, "the hello cadence must be one checksum cycle")
	await _teardown_arm(barrier_match)
	var plain_arm := await _boot_arm(0, "ws://test/room")
	var plain_match = plain_arm["match"]
	_expect(plain_match.command_bus().input_delay_ticks == 0, "a plain room must retain the existing zero delay boot")
	_expect(not plain_match.is_waiting_for_players(), "a plain room must not enter gathering")
	_expect(plain_match.advance_ticks(3) == 3, "a plain room must advance normally")
	await _teardown_arm(plain_match)


func _test_floor_measurement_is_not_change() -> void:
	var arm := await _boot_arm(2, "ws://test/room")
	var match_instance = arm["match"]
	var hub = arm["hub"]
	var peer_data := _new_peer(hub)
	_release_directly(match_instance, hub, peer_data["peer"])
	peer_data["peer"].announce_horizon(47)
	hub.step()
	match_instance._poll_turn_barrier(400)
	match_instance.advance_ticks(MatchScript.PING_INTERVAL_CADENCE_CYCLES * MatchScript.CHECKSUM_INTERVAL_TICKS)
	hub.step()
	peer_data["peer"].advance_tick(match_instance.current_tick())
	hub.step()
	match_instance.advance_ticks(1)
	_expect(match_instance.rtt_tracker().known_peer_count() == 1, "the post-release ping must measure the peer")
	_expect(match_instance.command_bus().input_delay_ticks == 2, "a one-tick RTT recommendation must preserve the floor")
	_expect(match_instance.input_delay_change_count() == 0, "re-applying the seeded floor must not count as a change")
	_expect(peer_data["peer"].rejected_frame_count() == 0, "the peer must accept the co-cadenced frames")
	await _teardown_arm(match_instance)


func _test_count_without_room() -> void:
	var arm := await _boot_arm(2, "", false)
	var match_instance = arm["match"]
	_expect(not match_instance.is_waiting_for_players(), "a count without a relay room must not wait forever")
	_expect(match_instance.advance_ticks(3) == 3, "a count without a room must retain normal ticking")
	await _teardown_arm(match_instance)


func _test_one_player_is_no_barrier() -> void:
	var arm := await _boot_arm(1, "ws://test/room")
	var match_instance = arm["match"]
	_expect(not match_instance.is_waiting_for_players(), "one expected player must not create a gathering barrier")
	_expect(match_instance.command_bus().input_delay_ticks == 0, "one player must not seed network delay")
	_expect(match_instance.advance_ticks(3) == 3, "one player with a room must advance normally")
	await _teardown_arm(match_instance)


func _teardown_arm(match_instance) -> void:
	match_instance.queue_free()
	await process_frame
	await process_frame
	for group_name in SIM_GROUPS:
		_expect(get_nodes_in_group(group_name).is_empty(), "teardown must leave %s empty before the next arm" % group_name)
