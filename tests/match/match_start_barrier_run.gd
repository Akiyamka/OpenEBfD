extends "res://tests/support/suite.gd"

const LegacyRulesFixture := preload("res://tests/support/legacy_rules_fixture.gd")
const ChecksumExchangeScript := preload("res://scripts/net/checksum_exchange.gd")
const LoopbackHubScript := preload("res://scripts/net/loopback_hub.gd")
const MatchFixtureScene := preload("res://tests/fixtures/websocket_match_fixture.tscn")
const LocalMatchFixtureScene := preload("res://tests/fixtures/match_fixture.tscn")
const MatchScript := preload("res://scripts/match/match.gd")
const MatchSnapshotScript := preload("res://scripts/match/match_snapshot.gd")
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
	await _run_async_case("invalid raw seed faults and stays visible", _test_invalid_seed_status)
	await _run_async_case("a follower binds START despite a different local override", _test_follower_seed_notice)
	await _run_async_case("a frame-driven follower binds START before tick one", _test_process_follower_binding)
	await _run_async_case("sequential restored peers bind one START seed and detect one-sided state", _test_gathered_snapshots)
	_finish("Match start barrier tests")


func _boot_arm(player_count := 0, room_url := "", with_transport := true, player_id := 1, seed_args := PackedStringArray(), snapshot_path := "") -> Dictionary:
	var hub := LoopbackHubScript.new()
	var endpoint = hub.add_endpoint(&"match") if with_transport else null
	var match_instance = MatchFixtureScene.instantiate()
	match_instance.local_player_id_for_test = player_id
	match_instance.match_seed_args_for_test = seed_args
	match_instance.snapshot_path_for_test = snapshot_path
	match_instance.restore_startup_for_test = not snapshot_path.is_empty()
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


func _new_peer(hub, player_id := 2) -> Dictionary:
	var endpoint = hub.add_endpoint(&"peer2")
	endpoint.open("")
	var bus := SimCommandBusScript.new()
	bus.input_delay_ticks = 2
	var peer = TurnSchedulerScript.new(bus, endpoint, player_id, ChecksumExchangeScript.new())
	peer.begin_gathering(2, 320)
	if player_id == 1:
		peer.set_start_proposal(456)
	peer.begin_turn_barrier(2, 320)
	return {"endpoint": endpoint, "bus": bus, "peer": peer}


func _release_directly(match_instance, hub, peer) -> void:
	for now_msec in [0, 20, 40, 320, 340, 360]:
		match_instance.turn_scheduler().poll_gathering(now_msec)
		peer.poll_gathering(now_msec)
		hub.step()


func _test_invalid_seed_status() -> void:
	var arm := await _boot_arm(2, "ws://test/room", true, 1, PackedStringArray(["--match-seed=0"]))
	var match_instance = arm["match"]
	_expect(not match_instance.startup_error().is_empty(), "invalid raw seed reaches startup fault")
	_expect(match_instance.advance_ticks(1) == 0, "startup fault refuses tick one")
	var peer_data := _new_peer(arm["hub"])
	for now_msec in [0, 20, 40, 320, 340, 360]:
		match_instance._poll_start_barrier()
		peer_data["peer"].poll_gathering(now_msec)
		arm["hub"].step()
	_expect(match_instance.selection_label.text.contains("Invalid --match-seed"), "waiting label must keep the startup error visible")
	_expect(match_instance.is_waiting_for_players(), "invalid leader never proposes START")
	await _teardown_arm(match_instance)


func _test_follower_seed_notice() -> void:
	var arm := await _boot_arm(2, "ws://test/room", true, 2, PackedStringArray(["--match-seed=999"]))
	var match_instance = arm["match"]
	_expect(match_instance.match_seed() == 0, "gathered follower is unbound before START")
	var peer_data := _new_peer(arm["hub"], 1)
	_release_directly(match_instance, arm["hub"], peer_data["peer"])
	peer_data["peer"].announce_horizon(0)
	arm["hub"].step()
	match_instance.turn_scheduler().advance_tick(0)
	_expect(match_instance.advance_ticks(1) == 1, "direct scheduler release binds before tick one")
	_expect(match_instance.match_seed() == 456, "echoed leader seed is authoritative")
	_expect(not match_instance.seed_notice().is_empty(), "different valid follower override has a notice")
	peer_data["endpoint"].send(peer_data["peer"]._encode_start_frame(457))
	arm["hub"].step()
	_expect(match_instance.advance_ticks(1) == 1 and match_instance.startup_error().contains("Conflicting START"), "conflicting duplicate refuses later ticks")
	_expect(match_instance.selection_label.text.contains("Conflicting START"), "protocol fault remains visible")
	await _teardown_arm(match_instance)


func _test_process_follower_binding() -> void:
	var arm := await _boot_arm(2, "ws://test/room", true, 2)
	var match_instance = arm["match"]
	var peer_data := _new_peer(arm["hub"], 1)
	peer_data["peer"].set_start_proposal(321)
	match_instance.set_process(true)
	var deadline := Time.get_ticks_msec() + 1500
	while match_instance.is_waiting_for_players() and Time.get_ticks_msec() < deadline:
		arm["hub"].step()
		peer_data["peer"].poll_gathering(Time.get_ticks_msec())
		await process_frame
	peer_data["peer"].announce_horizon(16)
	arm["hub"].step()
	while match_instance.current_tick() == 0 and Time.get_ticks_msec() < deadline:
		arm["hub"].step()
		await process_frame
	_expect(match_instance.current_tick() > 0 and match_instance.match_seed() == 321, "frame path binds echoed seed before first tick")
	await _teardown_arm(match_instance)


func _write_snapshot(path: String, seed: int, shift_building := false) -> void:
	var source = LocalMatchFixtureScene.instantiate()
	root.add_child(source)
	source.set_process(false)
	var snapshot = MatchSnapshotScript.new(path)
	snapshot.save(source.get_node("Buildings"), source.get_node("Units"), seed, 0, 0)
	source.free()
	if shift_building:
		var state: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(path))
		var building: Dictionary = state["buildings"][0]
		var transform: Dictionary = building["transform"]
		var origin: Array = transform["origin"]
		origin[0] = float(origin[0]) + 24.0
		var file := FileAccess.open(path, FileAccess.WRITE)
		file.store_string(JSON.stringify(state))
		file.close()


func _remove_snapshot(path: String) -> void:
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path))


func _cover_ticks(arm: Dictionary, peer, through_tick: int) -> void:
	peer.announce_horizon(through_tick)
	arm["hub"].step()
	arm["match"].turn_scheduler().advance_tick(0)


func _test_gathered_snapshots() -> void:
	const LEADER_PATH := "user://barrier_leader_seed_test.json"
	const FOLLOWER_PATH := "user://barrier_follower_seed_test.json"
	_remove_snapshot(LEADER_PATH)
	_remove_snapshot(FOLLOWER_PATH)
	_write_snapshot(LEADER_PATH, 777, true)
	var copy := FileAccess.get_file_as_string(LEADER_PATH)
	var copy_file := FileAccess.open(FOLLOWER_PATH, FileAccess.WRITE)
	copy_file.store_string(copy)
	copy_file.close()
	var leader_arm := await _boot_arm(2, "ws://test/room", true, 1, PackedStringArray(), LEADER_PATH)
	var leader = leader_arm["match"]
	var follower_peer := _new_peer(leader_arm["hub"])
	_release_directly(leader, leader_arm["hub"], follower_peer["peer"])
	_expect(follower_peer["peer"].bound_start_seed() == 777, "leader proposes restored seed after begin_gathering")
	_cover_ticks(leader_arm, follower_peer["peer"], 16)
	_expect(leader.advance_ticks(8) == 8, "restored leader reaches checksum tick")
	var leader_hash: int = int(leader.checksum_exchange()._local_hash_by_tick.get(8, -1))
	await _teardown_arm(leader)
	var follower_arm := await _boot_arm(2, "ws://test/room", true, 2, PackedStringArray(), FOLLOWER_PATH)
	var follower = follower_arm["match"]
	var raw_leader := _new_peer(follower_arm["hub"], 1)
	raw_leader["peer"].set_start_proposal(777)
	_release_directly(follower, follower_arm["hub"], raw_leader["peer"])
	_cover_ticks(follower_arm, raw_leader["peer"], 16)
	_expect(follower.advance_ticks(8) == 8 and follower.match_seed() == 777, "matching follower snapshot binds START before tick one")
	_expect(int(follower.checksum_exchange()._local_hash_by_tick.get(8, -1)) == leader_hash, "matching sequential snapshot arms agree at tick eight")
	await _teardown_arm(follower)
	var conflict_arm := await _boot_arm(2, "ws://test/room", true, 1, PackedStringArray(["--match-seed=778"]), LEADER_PATH)
	var conflict = conflict_arm["match"]
	var conflict_peer := _new_peer(conflict_arm["hub"])
	_release_directly(conflict, conflict_arm["hub"], conflict_peer["peer"])
	_expect(not conflict.startup_error().is_empty() and conflict_peer["peer"].bound_start_seed() == 0 and conflict.advance_ticks(1) == 0, "conflicting leader override faults and sends no START")
	await _teardown_arm(conflict)
	var mismatch_arm := await _boot_arm(2, "ws://test/room", true, 2, PackedStringArray(), FOLLOWER_PATH)
	var mismatch = mismatch_arm["match"]
	var mismatch_peer := _new_peer(mismatch_arm["hub"], 1)
	mismatch_peer["peer"].set_start_proposal(778)
	_release_directly(mismatch, mismatch_arm["hub"], mismatch_peer["peer"])
	_cover_ticks(mismatch_arm, mismatch_peer["peer"], 16)
	_expect(mismatch.advance_ticks(1) == 0 and not mismatch.startup_error().is_empty(), "follower snapshot seed mismatch refuses tick one visibly")
	_expect(mismatch.selection_label.text.contains("Snapshot seed differs"), "follower mismatch error remains on status line")
	await _teardown_arm(mismatch)
	var fresh_arm := await _boot_arm(2, "ws://test/room", true, 2)
	var fresh = fresh_arm["match"]
	var fresh_peer := _new_peer(fresh_arm["hub"], 1)
	fresh_peer["peer"].set_start_proposal(777)
	_release_directly(fresh, fresh_arm["hub"], fresh_peer["peer"])
	_cover_ticks(fresh_arm, fresh_peer["peer"], 16)
	_expect(fresh.advance_ticks(8) == 8, "one-sided snapshot follower reaches checksum tick")
	var fresh_hash: int = int(fresh.checksum_exchange()._local_hash_by_tick.get(8, -1))
	_expect(fresh_hash != leader_hash, "one-sided snapshot with different entities mismatches composite checksum")
	fresh.checksum_exchange().on_report_received(1, 8, leader_hash)
	fresh.advance_ticks(1)
	_expect(fresh.is_halted(), "one-sided snapshot report halts on checksum mismatch")
	await _teardown_arm(fresh)
	_remove_snapshot(LEADER_PATH)
	_remove_snapshot(FOLLOWER_PATH)


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
	_expect(match_instance.turn_scheduler().bound_start_seed() == peer_data["peer"].bound_start_seed() and match_instance.turn_scheduler().bound_start_seed() > 0, "relay echo gives both sides the same valid seed")
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
	_expect(plain_match.match_seed() == MatchScript.PLAIN_ROOM_SEED, "plain room uses fixed seed without gathering")
	_expect(plain_match.advance_ticks(3) == 3, "a plain room must advance normally")
	await _teardown_arm(plain_match)
	var override_arm := await _boot_arm(0, "ws://test/room", true, 1, PackedStringArray(["--match-seed=90210"]))
	_expect(override_arm["match"].match_seed() == 90210 and override_arm["match"].advance_ticks(1) == 1, "plain room valid override is authoritative")
	await _teardown_arm(override_arm["match"])


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
