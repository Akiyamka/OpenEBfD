extends SceneTree

const LegacyRulesFixture := preload("res://tests/support/legacy_rules_fixture.gd")
const MatchFixtureScene := preload("res://tests/fixtures/match_fixture.tscn")
const ReplayFileScript := preload("res://scripts/match/replay_file.gd")
const SimAttackCommandScript := preload("res://scripts/sim/commands/attack_command.gd")
const SimCommandCodecScript := preload("res://scripts/sim/command_codec.gd")
const SimMoveCommandScript := preload("res://scripts/sim/commands/move_command.gd")

const SCENE_PATH := "res://tests/fixtures/match_fixture.tscn"
const REPLAY_PATH := "user://replay_determinism_run.oebr"
const DIFFERING_REPLAY_PATH := "user://replay_determinism_different_run.oebr"
const REPLAY_TICKS := 12
const SIM_GROUPS: Array[StringName] = [
	&"sim_units", &"sim_linger_effects", &"sim_projectiles", &"sim_buildings", &"sim_spice_mounds",
]

var _assertions := 0
var _failures := 0
var _current_case := ""


func _initialize() -> void:
	LegacyRulesFixture.install(root)
	await _run_case("identical replays hash equal", _test_identical_replays_hash_equal)
	await _run_case("differing replays hash unequal", _test_differing_replays_hash_unequal)
	_remove_replay(REPLAY_PATH)
	_remove_replay(DIFFERING_REPLAY_PATH)
	if _failures > 0:
		printerr("Replay determinism tests: %d failures after %d assertions" % [_failures, _assertions])
		quit(1)
		return
	print("Replay determinism tests: %d assertions passed" % _assertions)
	quit(0)


func _run_case(case_name: String, test: Callable) -> void:
	_current_case = case_name
	var failures_before := _failures
	var assertions_before := _assertions
	await test.call()
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


func _test_identical_replays_hash_equal() -> void:
	var first := await _run_replay_arm(REPLAY_PATH, Vector3(20.0, 0.0, 0.0), true)
	var second := await _run_replay_arm(REPLAY_PATH, Vector3(20.0, 0.0, 0.0), false)
	_expect(bool(first["loaded"]) and bool(second["loaded"]), "both arms must load the same replay")
	_expect(bool(first["replay_exhausted"]) and bool(second["replay_exhausted"]), "both arms must consume every replay record")
	_expect(bool(first["moved"]) and bool(second["moved"]), "the replayed move must change ScoutA in both arms")
	_expect(bool(first["attacking"]) and bool(second["attacking"]), "the replayed attack must start an engagement in both arms")
	_expect(int(first["hash"]) == int(second["hash"]), "identical replays must finish with equal state hashes")


func _test_differing_replays_hash_unequal() -> void:
	var first := await _run_replay_arm(REPLAY_PATH, Vector3(20.0, 0.0, 0.0), true)
	var second := await _run_replay_arm(DIFFERING_REPLAY_PATH, Vector3(40.0, 0.0, 0.0), true)
	_expect(bool(first["loaded"]) and bool(second["loaded"]), "both control arms must load their replay")
	_expect(bool(first["replay_exhausted"]) and bool(second["replay_exhausted"]), "both control arms must consume every replay record")
	_expect(bool(first["moved"]) and bool(second["moved"]), "both control replays must execute their move command")
	_expect(bool(first["attacking"]) and bool(second["attacking"]), "both control replays must execute their attack command")
	_expect(int(first["hash"]) != int(second["hash"]), "different replay inputs must finish with different state hashes")


func _run_replay_arm(replay_path: String, move_offset: Vector3, write_replay: bool) -> Dictionary:
	var match_instance: Node = await _boot_arm()
	if write_replay:
		_write_replay(replay_path, match_instance, move_offset)
	var result := _load_and_run_replay(match_instance, replay_path)
	await _teardown_arm(match_instance)
	return result


func _boot_arm():
	var match_instance := MatchFixtureScene.instantiate()
	root.add_child(match_instance)
	match_instance.set_process(false)
	await process_frame
	match_instance.set_process(false)
	await process_frame
	match_instance.set_process(false)
	return match_instance


func _write_replay(replay_path: String, match_instance, move_offset: Vector3) -> void:
	_remove_replay(replay_path)
	var scout := match_instance.get_node("Units/ScoutA") as Unit
	var ordos_apc := match_instance.get_node("Units/OrdosAPC") as Unit
	var move := SimMoveCommandScript.new()
	move.player_id = scout.owner_player_id
	move.entity_ids = PackedInt32Array([scout.entity_id])
	move.target = scout.simulation_position() + move_offset
	move.move_mode = 0
	var attack := SimAttackCommandScript.new()
	attack.player_id = ordos_apc.owner_player_id
	attack.entity_ids = PackedInt32Array([ordos_apc.entity_id])
	attack.target_entity_id = scout.entity_id
	attack.target = scout.simulation_position()
	var file := FileAccess.open(replay_path, FileAccess.WRITE)
	ReplayFileScript.write_header(file, SCENE_PATH, "", 0, PackedByteArray())
	ReplayFileScript.write_record(file, 3, SimCommandCodecScript.encode(move))
	ReplayFileScript.write_record(file, 4, SimCommandCodecScript.encode(attack))
	file.close()


func _load_and_run_replay(match_instance, replay_path: String) -> Dictionary:
	var scout := match_instance.get_node("Units/ScoutA") as Unit
	var ordos_apc := match_instance.get_node("Units/OrdosAPC") as Unit
	var start_position := scout.simulation_position()
	var load_result: Dictionary = match_instance.load_replay(replay_path)
	_expect(bool(load_result.get("ok", false)), "the fixture replay must load: %s" % load_result.get("message", ""))
	match_instance.advance_ticks(REPLAY_TICKS)
	return {
		"loaded": bool(load_result.get("ok", false)),
		"replay_exhausted": match_instance.replay_exhausted(),
		"moved": not scout.simulation_position().is_equal_approx(start_position),
		"attacking": ordos_apc.has_attack_order(),
		"hash": match_instance.entity_state().state_hash(),
	}


func _teardown_arm(match_instance) -> void:
	match_instance.queue_free()
	await process_frame
	await process_frame
	for group_name in SIM_GROUPS:
		_expect(get_nodes_in_group(group_name).is_empty(), "teardown must leave %s empty before the next arm" % group_name)


func _remove_replay(replay_path: String) -> void:
	if FileAccess.file_exists(replay_path):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(replay_path))
