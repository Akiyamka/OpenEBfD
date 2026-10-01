extends "res://tests/support/suite.gd"

const LegacyRulesFixture := preload("res://tests/support/legacy_rules_fixture.gd")
const MatchFixtureScene := preload("res://tests/fixtures/match_fixture.tscn")

const SIM_GROUPS: Array[StringName] = [
	&"sim_units", &"sim_linger_effects", &"sim_projectiles", &"sim_buildings", &"sim_spice_mounds",
]


func _initialize() -> void:
	LegacyRulesFixture.install(root)
	await _run_async_case("a mismatch halts and reports its diverging tick", _test_halts_on_mismatch)
	await _run_async_case("a halted match stops its clock permanently", _test_clock_stays_stopped)
	await _run_async_case("a matching report does not halt", _test_matching_report_does_not_halt)
	await _run_async_case("an untouched match never halts", _test_untouched_match_never_halts)
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


func _boot_with_planted_mismatch() -> Array:
	var match_instance = await _boot_arm()
	match_instance.advance_ticks(8)
	var real: int = match_instance.entity_state().state_hash()
	match_instance.checksum_exchange().on_report_received(2, 8, real + 1)
	return [match_instance, real]


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
