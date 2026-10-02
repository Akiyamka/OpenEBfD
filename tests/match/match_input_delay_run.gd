extends "res://tests/support/suite.gd"

const LegacyRulesFixture := preload("res://tests/support/legacy_rules_fixture.gd")
const ChecksumExchangeScript := preload("res://scripts/net/checksum_exchange.gd")
const LoopbackHubScript := preload("res://scripts/net/loopback_hub.gd")
const MatchFixtureScene := preload("res://tests/fixtures/match_fixture.tscn")
const MatchScript := preload("res://scripts/match/match.gd")
const SimCommandBusScript := preload("res://scripts/sim/command_bus.gd")
const SimStopCommandScript := preload("res://scripts/sim/commands/stop_command.gd")
const TurnSchedulerScript := preload("res://scripts/net/turn_scheduler.gd")
const WebSocketMatchFixtureScene := preload("res://tests/fixtures/websocket_match_fixture.tscn")

const SIM_GROUPS: Array[StringName] = [
	&"sim_units", &"sim_linger_effects", &"sim_projectiles", &"sim_buildings", &"sim_spice_mounds",
]


func _initialize() -> void:
	LegacyRulesFixture.install(root)
	await _run_async_case("a match without measurements keeps its boot delay", _test_no_measurement_keeps_boot_delay)
	await _run_async_case("a measurement applies its recommendation", _test_measurement_applies_recommendation)
	await _run_async_case("a stable recommendation changes delay once", _test_stable_recommendation_changes_once)
	await _run_async_case("a changed recommendation applies again", _test_changed_recommendation_applies_again)
	await _run_async_case("an existing command keeps its target tick", _test_existing_command_keeps_target_tick)
	await _run_async_case("a hub round trip applies its recommendation", _test_hub_round_trip_applies_recommendation)
	await _run_async_case("a recommendation above the former ceiling applies in full", _test_large_recommendation_applies_in_full)
	_finish("Match input delay tests")


func _test_no_measurement_keeps_boot_delay() -> void:
	var match_instance = await _boot_arm()
	var boot_delay: int = match_instance.command_bus().input_delay_ticks
	match_instance.advance_ticks(200)
	_expect(match_instance.command_bus().input_delay_ticks == boot_delay, "a match with no measurements must keep its boot delay")
	_expect(match_instance.input_delay_change_count() == 0, "a match with no measurements must not emit a delay-change event")
	await _teardown_arm(match_instance)


func _test_measurement_applies_recommendation() -> void:
	var match_instance = await _boot_arm()
	match_instance.rtt_tracker().on_pong_received(2, 7)
	match_instance.advance_ticks(1)
	_expect(
		match_instance.command_bus().input_delay_ticks == match_instance.rtt_tracker().recommended_input_delay_ticks(),
		"a measured RTT above the floor must become the command bus delay"
	)
	_expect(match_instance.input_delay_change_count() == 1, "the first recommendation must emit one delay-change event")
	await _teardown_arm(match_instance)


func _test_stable_recommendation_changes_once() -> void:
	var match_instance = await _boot_arm()
	match_instance.rtt_tracker().on_pong_received(2, 7)
	match_instance.advance_ticks(1)
	var applied_delay: int = match_instance.command_bus().input_delay_ticks
	match_instance.advance_ticks(100)
	_expect(match_instance.command_bus().input_delay_ticks == applied_delay, "a stable recommendation must retain its applied delay")
	_expect(match_instance.input_delay_change_count() == 1, "a stable recommendation must not re-emit a delay-change event")
	await _teardown_arm(match_instance)


func _test_changed_recommendation_applies_again() -> void:
	var match_instance = await _boot_arm()
	match_instance.rtt_tracker().on_pong_received(2, 7)
	match_instance.advance_ticks(1)
	match_instance.rtt_tracker().on_pong_received(2, 11)
	match_instance.advance_ticks(1)
	_expect(
		match_instance.command_bus().input_delay_ticks == match_instance.rtt_tracker().recommended_input_delay_ticks(),
		"a changed recommendation must replace the previously applied delay"
	)
	_expect(match_instance.input_delay_change_count() == 2, "a changed recommendation must emit a second delay-change event")
	match_instance.rtt_tracker().on_pong_received(2, 11)
	match_instance.advance_ticks(1)
	_expect(match_instance.input_delay_change_count() == 2, "a pong with the same recommendation must not emit another event")
	await _teardown_arm(match_instance)


func _test_existing_command_keeps_target_tick() -> void:
	var match_instance = await _boot_arm()
	match_instance.rtt_tracker().on_pong_received(2, 7)
	match_instance.advance_ticks(1)
	var scout = match_instance.get_node("Units/ScoutA")
	scout._has_pending_navigation_order = true
	var command := SimStopCommandScript.new()
	command.player_id = MatchScript.LOCAL_PLAYER_ID
	command.entity_ids = PackedInt32Array([scout.entity_id])
	var original_target_tick: int = match_instance.turn_scheduler().submit_local(command, match_instance.current_tick())
	match_instance.rtt_tracker().on_pong_received(2, 11)
	match_instance.advance_ticks(1)
	_expect(
		match_instance.command_bus().input_delay_ticks == match_instance.rtt_tracker().recommended_input_delay_ticks(),
		"the case must apply a changed delay after scheduling the command"
	)
	while match_instance.current_tick() < original_target_tick - 1:
		match_instance.advance_ticks(1)
	_expect(scout._has_pending_navigation_order, "the Stop command must not execute before its original target tick")
	match_instance.advance_ticks(1)
	_expect(not scout._has_pending_navigation_order, "the Stop command must execute at its original target tick")
	_expect(match_instance.command_bus().dropped_late_count() == 0, "changing delay must not drop an existing command")
	await _teardown_arm(match_instance)


func _test_hub_round_trip_applies_recommendation() -> void:
	var arm := await _boot_hub_arm()
	var match_instance = arm["match"]
	var hub = arm["hub"]
	var peer = _new_answering_peer(hub, &"peer2", MatchScript.ENEMY_PLAYER_ID)
	match_instance.advance_ticks(_ping_interval())
	hub.step()
	peer.advance_tick(match_instance.current_tick())
	hub.step()
	match_instance.advance_ticks(1)
	_expect(
		match_instance.command_bus().input_delay_ticks == match_instance.rtt_tracker().recommended_input_delay_ticks(),
		"a real round trip must apply its recommendation to the command bus"
	)
	_expect(match_instance.input_delay_change_count() == 1, "one real measurement must emit one delay-change event")
	_expect(peer.rejected_frame_count() == 0, "the peer must accept the match's shared checksum and ping tick")
	await _teardown_arm(match_instance)


func _test_large_recommendation_applies_in_full() -> void:
	var match_instance = await _boot_arm()
	match_instance.rtt_tracker().on_pong_received(2, 25)
	match_instance.advance_ticks(1)
	_expect(
		match_instance.command_bus().input_delay_ticks == match_instance.rtt_tracker().recommended_input_delay_ticks(),
		"a recommendation above the former ceiling must apply without a cap"
	)
	_expect(match_instance.command_bus().input_delay_ticks == 25, "the high RTT recommendation must retain its full value")
	await _teardown_arm(match_instance)


func _ping_interval() -> int:
	return MatchScript.PING_INTERVAL_CADENCE_CYCLES * MatchScript.CHECKSUM_INTERVAL_TICKS


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
