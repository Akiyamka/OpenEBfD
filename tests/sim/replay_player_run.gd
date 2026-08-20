extends "res://tests/support/suite.gd"

## Pins down scripts/match/replay_player.gd, the playback half of the phase 2
## replay slice -- see docs/architecture/network-multiplayer.md, decision 10
## and phase 2 ("Replay recording and playback land here"), and ReplayPlayer's
## own doc comment for the timing and ordering rules this suite is proving.
## Lives beside tests/sim/replay_file_run.gd (the format) and
## tests/sim/command_bus_run.gd (the bus this class submits into) rather than
## under tests/match/: ReplayPlayer, like ReplayRecorder and ReplayFile, is a
## pure RefCounted class with no scene tree involved, so every case here
## drives it directly, the same style those two suites already use.
##
## The one case that gives this slice its meaning is
## _test_round_trip_record_playback_record_produces_identical_files: record a
## real match's command stream, play it back through a fresh bus, record that
## playback the same way Match does, and diff the two files byte for byte.
## Every other case here is a unit test of one rule in isolation; this one is
## the proof that the rules compose into "a replay reproduces itself".
##
## Every case writes to a uniquely named file under user://, same as
## tests/sim/replay_file_run.gd, and removes it when the case finishes,
## success or failure.

const ReplayFileScript := preload("res://scripts/match/replay_file.gd")
const ReplayRecorderScript := preload("res://scripts/match/replay_recorder.gd")
const ReplayPlayerScript := preload("res://scripts/match/replay_player.gd")
const SimCommandBusScript := preload("res://scripts/sim/command_bus.gd")
const SimStopCommandScript := preload("res://scripts/sim/commands/stop_command.gd")
const SimMoveCommandScript := preload("res://scripts/sim/commands/move_command.gd")
const SimAttackCommandScript := preload("res://scripts/sim/commands/attack_command.gd")
const SimBuildOrderCommandScript := preload("res://scripts/sim/commands/build_order_command.gd")
const SimCommandCodecScript := preload("res://scripts/sim/command_codec.gd")

const SCENE_PATH := "res://scenes/match/demo_match.tscn"


func _initialize() -> void:
	_run_case(
		"record -> playback -> record produces byte-identical replay files",
		_test_round_trip_record_playback_record_produces_identical_files
	)
	_run_case(
		"load() fails closed when snapshot_digest does not match the match's current digest",
		_test_load_fails_on_snapshot_digest_mismatch
	)
	_run_case(
		"an empty replay (header, zero records) plays back as a no-op and is exhausted immediately",
		_test_empty_replay_is_noop_and_exhausted_immediately
	)
	_run_case(
		"play_tick() drops a record whose tick playback has already passed, via submit_at()'s own late-drop rule",
		_test_play_tick_drops_a_record_whose_tick_has_already_passed
	)
	_finish("ReplayPlayer tests")


func _temp_path(case_id: String) -> String:
	return "user://replay_player_run_%s.oebr" % case_id


func _remove_if_exists(path: String) -> void:
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path))


## The round trip. The recording half submits through a real SimCommandBus
## and drains it exactly the way Match._advance_simulation_tick()
## (scripts/match/match.gd) does -- never a hand-built records list -- so this
## test proves something about the path the game actually uses, not about a
## fixture that merely looks like one.
##
## The recording and playback buses are given *different* input_delay_ticks
## (2 and 9) on purpose: submit_at() must ignore input_delay_ticks entirely
## (see SimCommandBus.submit_at()'s doc comment), so a correct playback
## reproduces the file byte for byte regardless of what either bus's delay
## happens to be set to. A playback that reconstructed the target tick via
## submit(command, tick) instead would place every command 9 ticks later
## than recorded, which this comparison would catch as a length and content
## mismatch, not merely a reordering.
##
## Tick 2 below carries three commands: two from player 1 (stop, then
## attack) and one from player 2 (move) submitted in between them. Two
## *different* players sharing a tick is not, by itself, sensitive to
## submission order -- SimCommandBus._drain_order() (scripts/sim/command_bus.gd)
## sorts by player_id first, so two different-player commands land in the
## same relative order regardless of which was submitted first, both at
## recording time and at playback time. The two player-1 commands are what
## actually exercises order preservation: their relative order is decided
## only by submission sequence (the tie-break _drain_order() falls back to
## when player_id is equal), so a playback that submitted this tick's
## records out of file order would flip stop and attack relative to each
## other while leaving player 2's command's position unchanged -- exactly
## the kind of drift a same-tick different-player pair alone cannot expose.
func _test_round_trip_record_playback_record_produces_identical_files() -> void:
	var record_path := _temp_path("round_trip_record")
	var playback_path := _temp_path("round_trip_playback")
	_remove_if_exists(record_path)
	_remove_if_exists(playback_path)

	# -- Recording --
	var record_bus := SimCommandBusScript.new()
	record_bus.input_delay_ticks = 2
	var recorder := ReplayRecorderScript.new()
	var start_result := recorder.start(record_path, SCENE_PATH, "")
	_expect(bool(start_result.get("ok", false)), "recorder must start: %s" % [start_result.get("message", "")])

	var stop_p1 := SimStopCommandScript.new()
	stop_p1.player_id = 1
	stop_p1.entity_ids = PackedInt32Array([5])

	var move_p2 := SimMoveCommandScript.new()
	move_p2.player_id = 2
	move_p2.entity_ids = PackedInt32Array([6])
	move_p2.target = Vector3(3.0, 0.0, 4.0)
	move_p2.move_mode = 1

	var attack_p1 := SimAttackCommandScript.new()
	attack_p1.player_id = 1
	attack_p1.entity_ids = PackedInt32Array([7])
	attack_p1.target = Vector3(11.0, 0.0, -9.0)
	attack_p1.target_entity_id = 42

	var build_p3 := SimBuildOrderCommandScript.new()
	build_p3.player_id = 3
	build_p3.building_id = &"ATBarracks"
	build_p3.button_index = MOUSE_BUTTON_LEFT

	# All three land on tick 2 (current_tick 0 + input_delay_ticks 2); build_p3
	# lands on tick 7. Submission order here (stop, move, attack) is
	# deliberately not the ascending-player_id order drain() will produce --
	# see this method's doc comment on why that only matters for the
	# same-player pair.
	record_bus.submit(stop_p1, 0)
	record_bus.submit(move_p2, 0)
	record_bus.submit(attack_p1, 0)
	record_bus.submit(build_p3, 5)

	var last_tick := 8
	for tick in range(0, last_tick + 1):
		var commands := record_bus.drain(tick)
		recorder.record_tick(tick, commands)
	recorder.stop()

	var sanity := ReplayFileScript.read(record_path)
	_expect(bool(sanity.get("ok", false)), "the recorded file itself must read back ok: %s" % [sanity.get("message", "")])
	_expect(
		(sanity.get("records", []) as Array).size() == 4,
		"test setup sanity: exactly 4 records must have been recorded, got %d"
		% (sanity.get("records", []) as Array).size()
	)

	# -- Playback: through the same drain(), a fresh bus and a second
	# recorder hooked to it the same way Match._advance_simulation_tick()
	# hooks the first (see scripts/match/match.gd). --
	var playback_bus := SimCommandBusScript.new()
	playback_bus.input_delay_ticks = 9

	var replay_player := ReplayPlayerScript.new()
	var load_result := replay_player.load(record_path, "")
	_expect(bool(load_result.get("ok", false)), "the recorded replay must load back: %s" % [load_result.get("message", "")])

	var second_recorder := ReplayRecorderScript.new()
	var second_start := second_recorder.start(playback_path, SCENE_PATH, "")
	_expect(bool(second_start.get("ok", false)), "second recorder must start: %s" % [second_start.get("message", "")])

	for tick in range(0, last_tick + 1):
		replay_player.play_tick(playback_bus, tick)
		var commands := playback_bus.drain(tick)
		second_recorder.record_tick(tick, commands)
	second_recorder.stop()

	_expect(
		replay_player.is_exhausted(),
		"every recorded command must have been submitted by the time playback reaches the last recorded tick"
	)
	_expect(playback_bus.dropped_late_count() == 0, "a fresh, in-step playback must never drop a command as late")

	var original_bytes := FileAccess.get_file_as_bytes(record_path)
	var replayed_bytes := FileAccess.get_file_as_bytes(playback_path)
	_expect(
		original_bytes == replayed_bytes,
		"record -> playback -> record must produce byte-identical files (original %d bytes, replayed %d bytes)"
		% [original_bytes.size(), replayed_bytes.size()]
	)

	_remove_if_exists(record_path)
	_remove_if_exists(playback_path)


## snapshot_digest is the entire reason ReplayFile's header carries it (see
## that class's doc comment): a replay must fail to load, loudly, against a
## match whose current MatchSnapshot file does not match the one it was
## recorded against. Covers both directions -- a real digest mismatching
## another real digest, and a replay recorded with no snapshot (empty
## digest) mismatching a match that has one -- since ReplayFile's own doc
## comment calls out the empty-vs-present case by name as something that
## must fail rather than coincidentally pass.
func _test_load_fails_on_snapshot_digest_mismatch() -> void:
	var path := _temp_path("digest_mismatch")
	_remove_if_exists(path)
	var file := FileAccess.open(path, FileAccess.WRITE)
	ReplayFileScript.write_header(file, SCENE_PATH, "abc123", 0, PackedByteArray())
	file.close()

	var player := ReplayPlayerScript.new()
	var result := player.load(path, "def456")
	_expect(
		not bool(result.get("ok", true)),
		"a replay whose snapshot_digest does not match the match's current digest must fail to load"
	)
	_expect(not String(result.get("message", "")).is_empty(), "a closed failure must carry a message naming the mismatch")
	_expect(not player.is_loaded(), "a failed load must not leave the player thinking a replay is loaded")
	_expect(player.is_exhausted(), "a player with nothing loaded must report itself exhausted, not mid-playback")

	_remove_if_exists(path)

	var empty_digest_path := _temp_path("digest_mismatch_empty")
	_remove_if_exists(empty_digest_path)
	var empty_digest_file := FileAccess.open(empty_digest_path, FileAccess.WRITE)
	ReplayFileScript.write_header(empty_digest_file, SCENE_PATH, "", 0, PackedByteArray())
	empty_digest_file.close()

	var empty_digest_player := ReplayPlayerScript.new()
	var empty_digest_result := empty_digest_player.load(empty_digest_path, "def456")
	_expect(
		not bool(empty_digest_result.get("ok", true)),
		"a replay recorded with no snapshot (empty digest) must fail to load against a match that has one"
	)

	_remove_if_exists(empty_digest_path)


func _test_empty_replay_is_noop_and_exhausted_immediately() -> void:
	var path := _temp_path("empty_playback")
	_remove_if_exists(path)
	var file := FileAccess.open(path, FileAccess.WRITE)
	ReplayFileScript.write_header(file, SCENE_PATH, "", 0, PackedByteArray())
	file.close()

	var player := ReplayPlayerScript.new()
	var load_result := player.load(path, "")
	_expect(bool(load_result.get("ok", false)), "a header-only replay must still load: %s" % [load_result.get("message", "")])
	_expect(player.is_loaded(), "a successful load must leave the player loaded")
	_expect(
		player.is_exhausted(),
		"an empty replay must report itself exhausted immediately -- there is nothing recorded to submit"
	)

	var bus := SimCommandBusScript.new()
	player.play_tick(bus, 1)
	_expect(bus.pending_count() == 0, "an empty replay's play_tick() must submit nothing")
	_expect(bus.dropped_late_count() == 0, "an empty replay's play_tick() must drop nothing either -- there is nothing to drop")

	_remove_if_exists(path)


## Mirrors submit_at()'s own late-drop test in tests/sim/replay_file_run.gd,
## through ReplayPlayer instead of directly: a record whose recorded tick is
## at or before the tick playback has already reached must be dropped and
## counted, exactly as any other late command is (see SimCommandBus.submit_at()'s
## doc comment) -- never sneaked onto whatever tick play_tick() happens to be
## called with instead. drain(10) below marks tick 10 as already drained,
## the same setup tests/sim/replay_file_run.gd's own
## _test_submit_at_ignores_delay_and_drops_late uses; play_tick() is then
## asked for tick 10 directly, skipping every earlier tick, simulating
## playback having resumed partway through a match.
func _test_play_tick_drops_a_record_whose_tick_has_already_passed() -> void:
	var path := _temp_path("late_drop")
	_remove_if_exists(path)

	var command := SimStopCommandScript.new()
	command.player_id = 1
	command.entity_ids = PackedInt32Array([1])

	var file := FileAccess.open(path, FileAccess.WRITE)
	ReplayFileScript.write_header(file, SCENE_PATH, "", 0, PackedByteArray())
	ReplayFileScript.write_record(file, 3, SimCommandCodecScript.encode(command))
	file.close()

	var player := ReplayPlayerScript.new()
	var load_result := player.load(path, "")
	_expect(bool(load_result.get("ok", false)), "a well-formed replay must load: %s" % [load_result.get("message", "")])

	var bus := SimCommandBusScript.new()
	bus.drain(10)

	player.play_tick(bus, 10)

	_expect(
		bus.dropped_late_count() == 1,
		"a record targeting tick 3 must be dropped, via submit_at()'s own late-drop rule, once playback has reached tick 10"
	)
	_expect(bus.pending_count() == 0, "a dropped record must never enter the pending queue")
	_expect(player.is_exhausted(), "the record must still be consumed (and dropped), not left stuck forever")

	_remove_if_exists(path)

