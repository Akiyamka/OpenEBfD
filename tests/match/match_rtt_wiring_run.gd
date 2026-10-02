extends "res://tests/support/suite.gd"

const LegacyRulesFixture := preload("res://tests/support/legacy_rules_fixture.gd")
const ChecksumExchangeScript := preload("res://scripts/net/checksum_exchange.gd")
const LoopbackHubScript := preload("res://scripts/net/loopback_hub.gd")
const MatchFixtureScene := preload("res://tests/fixtures/recording_transport_match_fixture.tscn")
const MatchScript := preload("res://scripts/match/match.gd")
const SimCommandBusScript := preload("res://scripts/sim/command_bus.gd")
const TurnSchedulerScript := preload("res://scripts/net/turn_scheduler.gd")
const WebSocketMatchFixtureScene := preload("res://tests/fixtures/websocket_match_fixture.tscn")

const SIM_GROUPS: Array[StringName] = [
	&"sim_units", &"sim_linger_effects", &"sim_projectiles", &"sim_buildings", &"sim_spice_mounds",
]


func _initialize() -> void:
	LegacyRulesFixture.install(root)
	await _run_async_case("pings are sent every six checksum cycles", _test_ping_cadence)
	await _run_async_case("a live round trip records one peer RTT", _test_round_trip_records_peer_rtt)
	await _run_async_case("a sent ping is not an RTT measurement", _test_ping_without_pong_is_not_measurement)
	await _run_async_case("a match does not measure its own ping echo", _test_local_ping_echo_is_ignored)
	await _run_async_case("two peers retain independent RTT measurements", _test_two_peers_are_measured_independently)
	await _run_async_case("a measured RTT applies the live input delay", _test_measurement_applies_input_delay)
	_finish("Match RTT wiring tests")


func _ping_interval() -> int:
	return MatchScript.PING_INTERVAL_CADENCE_CYCLES * MatchScript.CHECKSUM_INTERVAL_TICKS


func _test_ping_cadence() -> void:
	var match_instance = await _boot_arm()
	match_instance.advance_ticks(_ping_interval() * 2)
	var ping_frame_count := 0
	for sent_frame in match_instance.recording_transport.sent_frames:
		if not sent_frame.is_empty() and sent_frame[0] == 2:
			ping_frame_count += 1
	_expect(ping_frame_count == 2, "two intervals must emit exactly two ping frames")
	await _teardown_arm(match_instance)


func _test_round_trip_records_peer_rtt() -> void:
	var arm := await _boot_hub_arm()
	var match_instance = arm["match"]
	var hub = arm["hub"]
	var peer = _new_answering_peer(hub, &"peer2", MatchScript.ENEMY_PLAYER_ID)
	match_instance.advance_ticks(_ping_interval())
	var sent_tick: int = match_instance.current_tick()
	hub.step()
	peer.advance_tick(sent_tick)
	hub.step()
	match_instance.advance_ticks(1)
	var received_tick: int = match_instance.current_tick()
	_expect(
		match_instance.rtt_tracker().rtt_ticks_for(2) == received_tick - sent_tick,
		"the tracker must retain the ping-to-pong interval measured in match ticks"
	)
	_expect(match_instance.rtt_tracker().known_peer_count() == 1, "one answering peer must produce one measurement")
	_expect(peer.rejected_frame_count() == 0, "a peer must accept co-cadenced checksum and ping frames")
	await _teardown_arm(match_instance)


func _test_ping_without_pong_is_not_measurement() -> void:
	var arm := await _boot_hub_arm()
	var match_instance = arm["match"]
	var hub = arm["hub"]
	_new_answering_peer(hub, &"peer2", MatchScript.ENEMY_PLAYER_ID)
	_expect(match_instance.rtt_tracker().rtt_ticks_for(2) == -1, "a fresh tracker must not invent an RTT")
	_expect(match_instance.rtt_tracker().known_peer_count() == 0, "a fresh tracker must know no peers")
	match_instance.advance_ticks(_ping_interval())
	hub.step()
	match_instance.advance_ticks(1)
	_expect(match_instance.rtt_tracker().rtt_ticks_for(2) == -1, "a ping without a peer poll must not measure RTT")
	_expect(match_instance.rtt_tracker().known_peer_count() == 0, "a sent ping alone must not add a peer measurement")
	await _teardown_arm(match_instance)


func _test_local_ping_echo_is_ignored() -> void:
	var arm := await _boot_hub_arm()
	var match_instance = arm["match"]
	var hub = arm["hub"]
	match_instance.advance_ticks(_ping_interval())
	hub.step()
	match_instance.advance_ticks(1)
	hub.step()
	match_instance.advance_ticks(1)
	_expect(
		match_instance.turn_scheduler().last_remote_activity_tick_for(MatchScript.LOCAL_PLAYER_ID) == -1,
		"a local ping echo must not establish local remote activity"
	)
	_expect(match_instance.rtt_tracker().known_peer_count() == 0, "a local ping echo must not create a local RTT")
	await _teardown_arm(match_instance)


func _test_two_peers_are_measured_independently() -> void:
	var arm := await _boot_hub_arm()
	var match_instance = arm["match"]
	var hub = arm["hub"]
	var peer_two = _new_answering_peer(hub, &"peer2", 2)
	var peer_three = _new_answering_peer(hub, &"peer3", 3)
	match_instance.advance_ticks(_ping_interval())
	var sent_tick: int = match_instance.current_tick()
	hub.step()
	peer_two.advance_tick(sent_tick)
	hub.step()
	match_instance.advance_ticks(1)
	peer_three.advance_tick(match_instance.current_tick())
	hub.step()
	match_instance.advance_ticks(1)
	var peer_two_rtt: int = match_instance.rtt_tracker().rtt_ticks_for(2)
	var peer_three_rtt: int = match_instance.rtt_tracker().rtt_ticks_for(3)
	_expect(peer_two_rtt != peer_three_rtt, "delivering pongs on separate match ticks must retain distinct RTTs")
	_expect(match_instance.rtt_tracker().known_peer_count() == 2, "two answering peers must produce two measurements")
	_expect(
		match_instance.rtt_tracker().worst_known_rtt_ticks() == maxi(peer_two_rtt, peer_three_rtt),
		"the tracker must retain the larger independent RTT as its worst"
	)
	_expect(peer_two.rejected_frame_count() == 0, "the first peer must accept the match's co-cadenced frames")
	_expect(peer_three.rejected_frame_count() == 0, "the second peer must accept the match's co-cadenced frames")
	await _teardown_arm(match_instance)


func _test_measurement_applies_input_delay() -> void:
	var arm := await _boot_hub_arm()
	var match_instance = arm["match"]
	var hub = arm["hub"]
	var peer = _new_answering_peer(hub, &"peer2", MatchScript.ENEMY_PLAYER_ID)
	match_instance.advance_ticks(_ping_interval())
	hub.step()
	peer.advance_tick(match_instance.current_tick())
	hub.step()
	match_instance.advance_ticks(1)
	_expect(match_instance.rtt_tracker().known_peer_count() == 1, "the case must establish a real RTT measurement")
	_expect(
		match_instance.command_bus().input_delay_ticks == match_instance.rtt_tracker().recommended_input_delay_ticks(),
		"measuring RTT must apply the tracker recommendation to the live command bus"
	)
	_expect(
		match_instance.input_delay_change_count() == 1,
		"the first measured recommendation must produce one input-delay change event"
	)
	_expect(peer.rejected_frame_count() == 0, "the peer must accept the shared checksum and ping tick")
	await _teardown_arm(match_instance)


func _boot_hub_arm() -> Dictionary:
	var hub := LoopbackHubScript.new()
	var match_endpoint = hub.add_endpoint(&"match")
	var match_instance = WebSocketMatchFixtureScene.instantiate()
	match_instance.local_player_id_for_test = MatchScript.LOCAL_PLAYER_ID
	match_instance.net_room_url_for_test = ""
	match_instance.transport_override = match_endpoint
	root.add_child(match_instance)
	match_instance.set_process(false)
	await process_frame
	match_instance.set_process(false)
	await process_frame
	match_instance.set_process(false)
	return {"hub": hub, "match": match_instance}


func _new_answering_peer(hub, endpoint_id: StringName, player_id: int):
	var endpoint = hub.add_endpoint(endpoint_id)
	endpoint.open("")
	return TurnSchedulerScript.new(
		SimCommandBusScript.new(), endpoint, player_id, ChecksumExchangeScript.new()
	)


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
