extends "res://tests/support/suite.gd"

const LegacyRulesFixture := preload("res://tests/support/legacy_rules_fixture.gd")
const MatchFixtureScene := preload("res://tests/fixtures/match_fixture.tscn")
const WebsocketFixtureScene := preload("res://tests/fixtures/websocket_match_fixture.tscn")
const MatchSnapshotScript := preload("res://scripts/match/match_snapshot.gd")
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
	await _run_async_case("replay metadata installs only at local tick zero", _test_replay_load_guards)
	await _run_async_case("restored snapshot seed must match replay seed", _test_snapshot_seed_guard)
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
	ReplayFileScript.write_header(file, SCENE_PATH, "", 123456789, PackedByteArray([0, 0, 0, 0, 0, 0, 0, 3, 0x12, 0x34, 0x56, 0x78]))
	ReplayFileScript.write_record(file, 3, SimCommandCodecScript.encode(command))
	file.close()

	var load_result: Dictionary = match_instance.load_replay(REPLAY_PATH)
	_expect(bool(load_result.get("ok", false)), "the fixture replay must load: %s" % load_result.get("message", ""))
	_expect(match_instance.match_seed() == 123456789 and match_instance.sim_rng().draw_count == 3 and match_instance.sim_rng().draw_signature == 0x12345678, "recorded seed and audit install before commands")
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


func _write_header(path: String, scene: String, digest: String, seed: int, old_version := false) -> void:
	var file := FileAccess.open(path, FileAccess.WRITE)
	ReplayFileScript.write_header(file, scene, digest, seed, PackedByteArray([0, 0, 0, 0, 0, 0, 0, 2, 0, 0, 0, 7]))
	file.close()
	if old_version:
		var bytes := FileAccess.get_file_as_bytes(path)
		bytes[5] = 1
		file = FileAccess.open(path, FileAccess.WRITE)
		file.store_buffer(bytes)
		file.close()


func _boot_local():
	var match_instance = MatchFixtureScene.instantiate()
	root.add_child(match_instance)
	match_instance.set_process(false)
	await process_frame
	match_instance.set_process(false)
	return match_instance


func _test_replay_load_guards() -> void:
	var match_instance = await _boot_local()
	var seed: int = match_instance.match_seed()
	_write_header(REPLAY_PATH, SCENE_PATH, "", 77, true)
	_expect(not bool(match_instance.load_replay(REPLAY_PATH).get("ok", true)) and match_instance.match_seed() == seed and not match_instance._replay_player.is_loaded(), "version-one load leaves live seed and player unchanged")
	_write_header(REPLAY_PATH, SCENE_PATH, "", 77)
	match_instance.advance_ticks(1)
	_expect(not bool(match_instance.load_replay(REPLAY_PATH).get("ok", true)) and match_instance.match_seed() == seed and not match_instance._replay_player.is_loaded(), "late load leaves live seed and player unchanged")
	match_instance.queue_free()
	await process_frame
	var room = WebsocketFixtureScene.instantiate()
	room.net_room_url_for_test = "ws://test/room"
	root.add_child(room)
	room.set_process(false)
	await process_frame
	room.set_process(false)
	_write_header(REPLAY_PATH, "res://tests/fixtures/websocket_match_fixture.tscn", "", 77)
	var room_seed: int = room.match_seed()
	_expect(not bool(room.load_replay(REPLAY_PATH).get("ok", true)) and room.match_seed() == room_seed and not room._replay_player.is_loaded(), "valid same-scene room replay is refused before mutation")
	room.queue_free()
	await process_frame
	_remove_replay()


func _test_snapshot_seed_guard() -> void:
	const SNAPSHOT_PATH := "user://headless_replay_snapshot_test.json"
	var setup = await _boot_local()
	var snapshot = MatchSnapshotScript.new(SNAPSHOT_PATH)
	_expect(bool(snapshot.save(setup.get_node("Buildings"), setup.get_node("Units"), 55, 0, 0).get("ok", false)), "snapshot setup saves valid metadata")
	setup.queue_free()
	await process_frame
	var match_instance = MatchFixtureScene.instantiate()
	match_instance.restore_startup_for_test = true
	match_instance.snapshot_path_for_test = SNAPSHOT_PATH
	root.add_child(match_instance)
	match_instance.set_process(false)
	await process_frame
	match_instance.set_process(false)
	var digest := FileAccess.get_sha256(SNAPSHOT_PATH)
	_write_header(REPLAY_PATH, SCENE_PATH, digest, 56)
	_expect(not bool(match_instance.load_replay(REPLAY_PATH).get("ok", true)) and match_instance.match_seed() == 55 and not match_instance._replay_player.is_loaded(), "same digest but different replay seed is refused")
	_write_header(REPLAY_PATH, SCENE_PATH, digest, 55)
	_expect(bool(match_instance.load_replay(REPLAY_PATH).get("ok", false)), "matching snapshot seed and digest load")
	match_instance.queue_free()
	await process_frame
	snapshot.erase()
	_remove_replay()
