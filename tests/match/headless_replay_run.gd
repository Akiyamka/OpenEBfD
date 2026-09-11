extends "res://tests/support/suite.gd"

const LegacyRulesFixture := preload("res://tests/support/legacy_rules_fixture.gd")
const MatchFixtureScene := preload("res://tests/fixtures/match_fixture.tscn")
const ReplayFileScript := preload("res://scripts/match/replay_file.gd")
const SimCommandCodecScript := preload("res://scripts/sim/command_codec.gd")
const SimMoveCommandScript := preload("res://scripts/sim/commands/move_command.gd")

const SCENE_PATH := "res://tests/fixtures/match_fixture.tscn"
const REPLAY_PATH := "user://headless_replay_run.oebr"
const MAX_TICKS := 20


func _initialize() -> void:
	LegacyRulesFixture.install(root)
	await _run_async_case(
		"a booted Match replays commands through advance_ticks() without frame-driven ticks",
		_test_headless_replay
	)
	_finish("Headless replay tests")


func _test_headless_replay() -> void:
	_remove_replay()
	var match_instance := MatchFixtureScene.instantiate()
	root.add_child(match_instance)
	match_instance.set_process(false)
	await process_frame
	match_instance.set_process(false)
	await process_frame
	match_instance.set_process(false)

	_expect(
		match_instance.current_tick() == 0,
		"the boot settle must not advance Match's frame-driven clock before replay loading"
	)
	var scout := match_instance.get_node("Units/ScoutA") as Unit
	var start_position := scout.simulation_position()
	var command := SimMoveCommandScript.new()
	command.player_id = 1
	command.entity_ids = PackedInt32Array([scout.entity_id])
	command.target = start_position + Vector3(20.0, 0.0, 0.0)
	command.move_mode = 0
	var file := FileAccess.open(REPLAY_PATH, FileAccess.WRITE)
	ReplayFileScript.write_header(file, SCENE_PATH, "", 0, PackedByteArray())
	ReplayFileScript.write_record(file, 3, SimCommandCodecScript.encode(command))
	file.close()

	var load_result: Dictionary = match_instance.load_replay(REPLAY_PATH)
	_expect(bool(load_result.get("ok", false)), "the fixture replay must load: %s" % load_result.get("message", ""))
	var ticks := 0
	while not match_instance.replay_exhausted() and ticks < MAX_TICKS:
		match_instance.advance_ticks(1)
		ticks += 1
	_expect(match_instance.replay_exhausted(), "the replay must exhaust before the assertion-backed tick cap")
	_expect(ticks < MAX_TICKS, "the replay loop must finish before its tick cap")
	_expect(
		not scout.simulation_position().is_equal_approx(start_position),
		"the replayed move command must change its target unit's simulation position"
	)

	match_instance.queue_free()
	await process_frame
	_remove_replay()


func _remove_replay() -> void:
	if FileAccess.file_exists(REPLAY_PATH):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(REPLAY_PATH))
