extends "res://tests/support/suite.gd"

const LegacyRulesFixture := preload("res://tests/support/legacy_rules_fixture.gd")
const LoopbackHubScript := preload("res://scripts/net/loopback_hub.gd")
const MatchFixtureScene := preload("res://tests/fixtures/match_fixture.tscn")
const MatchScript := preload("res://scripts/match/match.gd")
const SimCommandBusScript := preload("res://scripts/sim/command_bus.gd")
const TurnSchedulerScript := preload("res://scripts/net/turn_scheduler.gd")
const WebSocketMatchFixtureScene := preload("res://tests/fixtures/websocket_match_fixture.tscn")

const SIM_GROUPS: Array[StringName] = [
	&"sim_units", &"sim_linger_effects", &"sim_projectiles", &"sim_buildings", &"sim_spice_mounds",
]


func _initialize() -> void:
	LegacyRulesFixture.install(root)
	await _run_async_case("a silent peer is never stalled", _test_silent_peer_is_not_stalled)
	await _run_async_case("the local player is never stalled", _test_local_player_is_not_stalled)
	await _run_async_case("a heard peer stalls after the threshold", _test_heard_peer_stalls_after_threshold)
	await _run_async_case("the stall threshold has a strict edge", _test_stall_threshold_is_strict)
	await _run_async_case("remote players are judged independently", _test_remote_players_are_judged_independently)
	await _run_async_case("a fresh frame clears a stalled verdict", _test_fresh_frame_clears_stalled_verdict)
	await _run_async_case("stalled player ids returns a defensive copy", _test_stalled_player_ids_returns_copy)
	await _run_async_case("a detached match has no stalled roster", _test_detached_match_has_no_stalled_roster)
	_finish("Match stall detection tests")


func _threshold() -> int:
	return MatchScript.STALL_THRESHOLD_CADENCE_CYCLES * MatchScript.CHECKSUM_INTERVAL_TICKS


func _test_silent_peer_is_not_stalled() -> void:
	var match_instance = await _boot_arm()
	match_instance.advance_ticks(_threshold() + 40)
	_expect(
		not match_instance.is_player_stalled(MatchScript.ENEMY_PLAYER_ID),
		"a peer that has never sent a frame must be absent rather than stalled"
	)
	_expect(match_instance.stalled_player_ids().is_empty(), "an unheard demo enemy must not enter the stalled roster")
	await _teardown_arm(match_instance)


func _test_local_player_is_not_stalled() -> void:
	var match_instance = await _boot_arm()
	match_instance.advance_ticks(_threshold() + 40)
	_expect(
		not match_instance.is_player_stalled(MatchScript.LOCAL_PLAYER_ID),
		"the local player must never be interpreted as a remote stalled peer"
	)
	await _teardown_arm(match_instance)


func _test_heard_peer_stalls_after_threshold() -> void:
	var arm := await _boot_hub_arm()
	var match_instance = arm["match"]
	var hub = arm["hub"]
	var peer = _new_send_only_peer(hub, &"peer2", MatchScript.ENEMY_PLAYER_ID)
	var activity_tick := _deliver_ping(match_instance, hub, peer)
	match_instance.advance_ticks(_threshold() + 1)
	_expect(match_instance.current_tick() - activity_tick > _threshold(), "the case must advance past the threshold")
	_expect(match_instance.is_player_stalled(2), "a previously heard silent peer must stall past the threshold")
	_expect(match_instance.stalled_player_ids() == [2], "the stalled roster must name the silent peer")
	await _teardown_arm(match_instance)


func _test_stall_threshold_is_strict() -> void:
	var arm := await _boot_hub_arm()
	var match_instance = arm["match"]
	var hub = arm["hub"]
	var peer = _new_send_only_peer(hub, &"peer2", MatchScript.ENEMY_PLAYER_ID)
	var activity_tick := _deliver_ping(match_instance, hub, peer)
	match_instance.advance_ticks(_threshold())
	_expect(
		match_instance.current_tick() == activity_tick + _threshold(),
		"the first edge assertion must land exactly at the configured threshold"
	)
	_expect(not match_instance.is_player_stalled(2), "the threshold itself must not count as stalled")
	match_instance.advance_ticks(1)
	_expect(
		match_instance.current_tick() == activity_tick + _threshold() + 1,
		"the second edge assertion must be one tick beyond the threshold"
	)
	_expect(match_instance.is_player_stalled(2), "one tick beyond the threshold must count as stalled")
	await _teardown_arm(match_instance)


func _test_remote_players_are_judged_independently() -> void:
	var arm := await _boot_hub_arm()
	var match_instance = arm["match"]
	var hub = arm["hub"]
	match_instance._players().create_player(3, "Peer Three", Color(0.8, 0.4, 0.2), &"Fremen", [], 3, 5000, 0)
	var peer_two = _new_send_only_peer(hub, &"peer2", 2)
	var peer_three = _new_send_only_peer(hub, &"peer3", 3)
	peer_two.send_ping(match_instance.current_tick())
	peer_three.send_ping(match_instance.current_tick())
	hub.step()
	match_instance.advance_ticks(1)
	var original_tick: int = match_instance.current_tick()
	match_instance.advance_ticks(_threshold() + 1)
	_expect(match_instance.current_tick() - original_tick > _threshold(), "both peers must first become stalled")
	_deliver_ping(match_instance, hub, peer_two)
	_expect(not match_instance.is_player_stalled(2), "the recently heard peer must recover independently")
	_expect(match_instance.is_player_stalled(3), "the still-silent peer must remain stalled")
	_expect(
		match_instance.turn_scheduler().last_remote_activity_tick_for(2)
		!= match_instance.turn_scheduler().last_remote_activity_tick_for(3),
		"independent peers must retain distinct activity ticks"
	)
	_expect(match_instance.stalled_player_ids() == [3], "only the silent third player must be in the stalled roster")
	await _teardown_arm(match_instance)


func _test_fresh_frame_clears_stalled_verdict() -> void:
	var arm := await _boot_hub_arm()
	var match_instance = arm["match"]
	var hub = arm["hub"]
	var peer = _new_send_only_peer(hub, &"peer2", MatchScript.ENEMY_PLAYER_ID)
	_deliver_ping(match_instance, hub, peer)
	match_instance.advance_ticks(_threshold() + 1)
	_expect(match_instance.is_player_stalled(2), "the peer must be stalled before the recovery frame")
	_deliver_ping(match_instance, hub, peer)
	_expect(not match_instance.is_player_stalled(2), "a fresh frame must clear the on-demand stalled verdict")
	await _teardown_arm(match_instance)


func _test_stalled_player_ids_returns_copy() -> void:
	var arm := await _boot_hub_arm()
	var match_instance = arm["match"]
	var hub = arm["hub"]
	var peer = _new_send_only_peer(hub, &"peer2", MatchScript.ENEMY_PLAYER_ID)
	_deliver_ping(match_instance, hub, peer)
	match_instance.advance_ticks(_threshold() + 1)
	var returned_ids: Array[int] = match_instance.stalled_player_ids()
	returned_ids.clear()
	_expect(match_instance.stalled_player_ids() == [2], "mutating one returned array must not affect the next read")
	await _teardown_arm(match_instance)


func _test_detached_match_has_no_stalled_roster() -> void:
	var match_instance = await _boot_arm()
	root.remove_child(match_instance)
	# Deliberately only a behavioural assertion. Removing stalled_player_ids()'
	# null-roster guard does not change what this case observes: the call on a
	# detached match returns the same empty Array[int] either way, logging a Nil
	# script error rather than returning anything different. The guard is kept
	# because every other _players() call site guards identically and an error
	# log is worth avoiding, but no test can distinguish its presence -- do not
	# "fix" that by asserting on match.gd's source text, which couples a test to
	# production formatting and misreports a reformat as a missing guard.
	_expect(match_instance.stalled_player_ids().is_empty(), "a match outside the tree must report no stalled roster")
	match_instance.free()


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


func _new_send_only_peer(hub, endpoint_id: StringName, player_id: int):
	var endpoint = hub.add_endpoint(endpoint_id)
	endpoint.open("")
	return TurnSchedulerScript.new(SimCommandBusScript.new(), endpoint, player_id)


func _deliver_ping(match_instance, hub, peer) -> int:
	peer.send_ping(match_instance.current_tick())
	hub.step()
	match_instance.advance_ticks(1)
	return match_instance.current_tick()


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
