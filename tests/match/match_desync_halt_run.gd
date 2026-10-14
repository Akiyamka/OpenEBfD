extends "res://tests/support/suite.gd"

const LegacyRulesFixture := preload("res://tests/support/legacy_rules_fixture.gd")
const MatchFixtureScene := preload("res://tests/fixtures/match_fixture.tscn")
const RecentCommandLogScript := preload("res://scripts/match/recent_command_log.gd")
const SimStopCommandScript := preload("res://scripts/sim/commands/stop_command.gd")
const TurnSchedulerScript := preload("res://scripts/net/turn_scheduler.gd")

const SIM_GROUPS: Array[StringName] = [
	&"sim_units", &"sim_linger_effects", &"sim_projectiles", &"sim_buildings", &"sim_spice_mounds",
]


func _initialize() -> void:
	LegacyRulesFixture.install(root)
	await _run_async_case("a mismatch halts and reports its diverging tick", _test_halts_on_mismatch)
	await _run_async_case("a halted match stops its clock permanently", _test_clock_stays_stopped)
	await _run_async_case("a matching report does not halt", _test_matching_report_does_not_halt)
	await _run_async_case("an untouched match never halts", _test_untouched_match_never_halts)
	await _run_async_case("a halt dumps stream evidence without changing V1", _test_halt_dump)
	await _run_async_case("a healthy match leaves the halt dump empty", _test_healthy_match_has_no_halt_dump)
	await _run_async_case("the recent list retains the oldest possible culprit", _test_recent_list_worst_case_halt)
	_run_case("per-player digests separate timing from content", _test_per_player_digests)
	_run_case("per-player summaries outlive the recent window", _test_summary_outlives_window)
	_run_case("losses on different players do not cancel", _test_cross_player_losses_do_not_cancel)
	_finish("Match desync halt tests")


func _test_halts_on_mismatch() -> void:
	var planted := await _boot_with_planted_mismatch()
	var match_instance = planted[0]
	var real: int = planted[1]
	_expect(not match_instance.is_halted(), "planting a report must not halt before a later tick runs")
	match_instance.advance_ticks(1)
	_expect(match_instance.is_halted(), "a resolved mismatch must halt on the next tick")
	_expect(match_instance.halted_at_tick() == 9, "the mismatch must halt at non-cadence tick 9")
	var mismatch: Dictionary = match_instance.checksum_exchange().last_mismatch()
	_expect(int(mismatch["tick"]) == 8, "the mismatch must identify the divergent tick")
	_expect(int(mismatch["local_hash"]) == real, "the mismatch must retain the recorded local hash")
	_expect(int(mismatch["remote_hash"]) == real + 1, "the mismatch must retain the planted remote hash")
	var expected := (
		"Match halted: simulation checksum diverged from player 2 at tick 8 (local %d, remote %d)"
		% [real, real + 1]
	)
	_expect(match_instance.halt_diagnostic() == expected, "the diagnostic must report the divergent tick and both hashes")
	await _teardown_arm(match_instance)


func _test_clock_stays_stopped() -> void:
	var planted := await _boot_with_planted_mismatch()
	var match_instance = planted[0]
	match_instance.advance_ticks(1)
	_expect(match_instance.is_halted(), "the planted mismatch must establish the halted precondition")
	_expect(match_instance.advance_ticks(50) == 9, "a halted match must return its unchanged tick boundary")
	_expect(match_instance.current_tick() == 9, "a halted match must not move its clock again")
	await _teardown_arm(match_instance)


func _test_matching_report_does_not_halt() -> void:
	var match_instance = await _boot_arm()
	match_instance.advance_ticks(8)
	var real: int = match_instance.entity_state().state_hash()
	match_instance.checksum_exchange().on_report_received(2, 8, real)
	_expect(match_instance.checksum_exchange().agreement_count() == 1, "the matching report must resolve as agreement")
	_expect(match_instance.checksum_exchange().mismatch_count() == 0, "the matching report must not become a mismatch")
	match_instance.advance_ticks(4)
	_expect(not match_instance.is_halted(), "agreement traffic must not halt the match")
	_expect(match_instance.halt_diagnostic() == "", "agreement traffic must leave no halt diagnostic")
	_expect(match_instance.current_tick() == 12, "the healthy match must continue through tick 12")
	await _teardown_arm(match_instance)


func _test_untouched_match_never_halts() -> void:
	var match_instance = await _boot_arm()
	match_instance.advance_ticks(24)
	_expect(not match_instance.is_halted(), "local checksum records alone must not halt the match")
	_expect(match_instance.current_tick() == 24, "an untouched match must advance through three cadence boundaries")
	_expect(match_instance.checksum_exchange().mismatch_count() == 0, "an untouched match must record no mismatch")
	await _teardown_arm(match_instance)


func _test_halt_dump() -> void:
	var match_instance = await _boot_arm()
	match_instance.command_bus().input_delay_ticks = 3
	var stop := _make_stop_command(1, 1)
	match_instance.command_bus().submit_at(stop, 5)
	match_instance._tick_driver.pending_ticks(1.0)
	match_instance.turn_scheduler()._rejected_frame_count = 4
	match_instance.advance_ticks(8)
	match_instance.command_bus().submit_at(_make_stop_command(1, 2), 1)
	var real: int = match_instance.entity_state().state_hash()
	match_instance.checksum_exchange().on_report_received(2, 8, real + 1)
	match_instance.advance_ticks(1)
	var description := TurnSchedulerScript.describe_command(stop)
	var dump: PackedStringArray = match_instance.halt_dump()
	_expect(
		dump.size() > 0 and dump[0] == "[desync] player 1 halted at tick 9: input_delay_ticks=3 dropped_late_count=1 dropped_ticks=20 rejected_frames=4",
		"the first dump line must report the planted scalar evidence"
	)
	_expect(
		dump.size() > 1 and dump[1] == "[desync] player 1 stream: executed 1, dropped late 0, content %08x, timed %08x" % [
			TurnSchedulerScript._fnv1a32((description + "\n").to_utf8_buffer()),
			TurnSchedulerScript._fnv1a32(("tick 5 %s\n" % description).to_utf8_buffer()),
		],
		"the player-one stream must report its command and both digests"
	)
	_expect(
		dump.size() > 2 and dump[2] == "[desync] player 2 stream: executed 0, dropped late 0, content 811c9dc5, timed 811c9dc5",
		"the empty roster player must retain an aligned stream line"
	)
	_expect(dump.size() > 3 and dump[3] == "[desync] commands executed in the last 80 ticks: 1", "the recent-list header must state its fixed window")
	_expect(dump.size() > 4 and dump[4] == "[desync] tick 5 player 1 " + description, "the recent list must identify the executed command")
	var expected := "Match halted: simulation checksum diverged from player 2 at tick 8 (local %d, remote %d)" % [real, real + 1]
	_expect(match_instance.halt_diagnostic() == expected, "the V1 diagnostic must remain exactly unchanged")
	await _teardown_arm(match_instance)


func _test_healthy_match_has_no_halt_dump() -> void:
	var match_instance = await _boot_arm()
	match_instance.command_bus().submit_at(_make_stop_command(1, 1), 3)
	match_instance.advance_ticks(24)
	_expect(match_instance.halt_dump().is_empty(), "a match that never halts must retain no halt dump")
	_expect(match_instance.turn_scheduler().late_drop_lines().is_empty(), "a null transport must retain no late-drop lines")
	await _teardown_arm(match_instance)


func _test_recent_list_worst_case_halt() -> void:
	var match_instance = await _boot_arm()
	match_instance.command_bus().submit_at(_make_stop_command(1, 1), 71)
	match_instance.command_bus().submit_at(_make_stop_command(1, 2), 73)
	match_instance.advance_ticks(80)
	var real: int = match_instance.entity_state().state_hash()
	match_instance.advance_ticks(71)
	match_instance.checksum_exchange().on_report_received(2, 80, real + 1)
	match_instance.advance_ticks(1)
	var dump: PackedStringArray = match_instance.halt_dump()
	_expect(
		match_instance.halted_at_tick() == 152 and int(match_instance.checksum_exchange().last_mismatch()["tick"]) == 80,
		"the latest retained report must halt at tick 152 for checksum tick 80"
	)
	_expect(_has_line_starting_with(dump, "[desync] tick 73 player 1 "), "the latest possible culprit must remain in the recent list")
	_expect(not _has_line_starting_with(dump, "[desync] tick 71 player 1 "), "entries older than the prune edge must leave the recent list")
	await _teardown_arm(match_instance)


func _test_per_player_digests() -> void:
	var log_a = RecentCommandLogScript.new(80)
	var log_b = RecentCommandLogScript.new(80)
	var log_c = RecentCommandLogScript.new(80)
	var log_d = RecentCommandLogScript.new(80)
	log_a.record(5, [_make_stop_command(1, 1)])
	log_a.record(9, [_make_stop_command(1, 2)])
	log_b.record(5, [_make_stop_command(1, 1)])
	log_b.record(9, [_make_stop_command(1, 2)])
	log_c.record(5, [_make_stop_command(1, 1)])
	log_c.record(10, [_make_stop_command(1, 2)])
	log_d.record(5, [_make_stop_command(1, 1)])
	log_d.record(9, [_make_stop_command(1, 3)])
	_expect(
		log_a.count_for(1) == log_b.count_for(1) and log_a.content_digest_for(1) == log_b.content_digest_for(1) and log_a.timed_digest_for(1) == log_b.timed_digest_for(1),
		"fresh decoded-equivalent commands must have identical summaries"
	)
	_expect(
		log_a.content_digest_for(1) == log_c.content_digest_for(1) and log_a.timed_digest_for(1) != log_c.timed_digest_for(1),
		"different execution ticks must change only the timed digest"
	)
	_expect(log_a.content_digest_for(1) != log_d.content_digest_for(1), "changed command content must change the content digest")


func _test_summary_outlives_window() -> void:
	var log = RecentCommandLogScript.new(80)
	log.record(1, [_make_stop_command(1, 1)])
	for tick in range(2, 201):
		log.record(tick, [])
	_expect(log.count_for(1) == 1, "pruning recent entries must not prune a player's whole-match count")
	_expect(log.recent_lines().size() == 1, "an expired stream must leave only the recent-list header")


func _test_cross_player_losses_do_not_cancel() -> void:
	var client_one_log = RecentCommandLogScript.new(80)
	var client_two_log = RecentCommandLogScript.new(80)
	client_one_log.record(5, [_make_stop_command(1, 1)])
	client_two_log.record(5, [_make_stop_command(2, 1)])
	_expect(
		client_one_log.count_for(1) != client_two_log.count_for(1) and client_one_log.count_for(2) != client_two_log.count_for(2),
		"separate player summaries must expose losses that a combined count would cancel"
	)


func _boot_with_planted_mismatch() -> Array:
	var match_instance = await _boot_arm()
	match_instance.advance_ticks(8)
	var real: int = match_instance.entity_state().state_hash()
	match_instance.checksum_exchange().on_report_received(2, 8, real + 1)
	return [match_instance, real]


func _make_stop_command(player_id: int, entity_id: int) -> SimStopCommand:
	var command = SimStopCommandScript.new()
	command.player_id = player_id
	command.entity_ids = PackedInt32Array([entity_id])
	return command


func _has_line_starting_with(lines: PackedStringArray, prefix: String) -> bool:
	for line in lines:
		if line.begins_with(prefix):
			return true
	return false


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
