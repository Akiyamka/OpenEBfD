extends "res://tests/support/suite.gd"

## Pins down scripts/match/replay_file.gd, the on-disk wire format for a
## recorded match -- see docs/architecture/network-multiplayer.md, decision
## 10 and phase 2 ("Replay recording and playback land here"). Lives beside
## command_codec_run.gd and command_bus_run.gd rather than under
## tests/match/: ReplayFile is a pure format class (no scene tree involved,
## exactly like SimCommandCodec), and it reuses SimCommandCodec directly for
## every payload it stores, so its test belongs with the other command-wire
## suites rather than with the scene-driven tests under tests/match/.
##
## Also covers SimCommandBus.submit_at() (scripts/sim/command_bus.gd), the
## sim-side half of this same slice: it exists specifically so replay
## playback can land a command on its recorded tick regardless of
## input_delay_ticks (see that method's doc comment), so its test sits here
## with the format it was added to serve rather than in
## tests/sim/command_bus_run.gd, which already covers submit()'s ordinary
## scheduling behaviour on its own.
##
## Every case writes to a uniquely named file under user://, which is
## writable in the headless container this suite runs in (see
## tools/run_godot_tests.sh), and removes it when the case finishes,
## success or failure, so one run never leaves a file the next run's
## same-named case could collide with.

const ReplayFileScript := preload("res://scripts/match/replay_file.gd")
const SimCommandBusScript := preload("res://scripts/sim/command_bus.gd")
const SimCommandScript := preload("res://scripts/sim/commands/sim_command.gd")
const SimCommandCodecScript := preload("res://scripts/sim/command_codec.gd")
const SimStopCommandScript := preload("res://scripts/sim/commands/stop_command.gd")
const SimMoveCommandScript := preload("res://scripts/sim/commands/move_command.gd")
const SimBuildOrderCommandScript := preload("res://scripts/sim/commands/build_order_command.gd")


func _initialize() -> void:
	_run_case("write_header()/read() round-trip every header field exactly", _test_header_round_trip)
	_run_case(
		"write_record() round-trips several command types across several ticks, reusing SimCommandCodec",
		_test_record_round_trip_multiple_types
	)
	_run_case(
		"two commands from different players on one tick keep the order they were written in",
		_test_same_tick_different_players_preserve_write_order
	)
	_run_case("read() fails closed on bad magic", _test_bad_magic_fails_closed)
	_run_case("read() fails closed on an unknown format_version", _test_unknown_format_version_fails_closed)
	_run_case(
		"a file truncated at several different offsets inside its last record yields every earlier record, flagged truncated",
		_test_truncated_tail_at_several_offsets
	)
	_run_case("a header-only file (zero records) reads back as a clean, non-truncated empty replay", _test_header_only_file_is_empty_replay)
	_run_case(
		"submit_at() schedules for the exact absolute tick given, ignoring input_delay_ticks, and still drops an already-drained tick",
		_test_submit_at_ignores_delay_and_drops_late
	)
	_finish("ReplayFile tests")


func _temp_path(case_id: String) -> String:
	return "user://replay_file_run_%s.oebr" % case_id


func _remove_if_exists(path: String) -> void:
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path))


func _test_header_round_trip() -> void:
	var path := _temp_path("header")
	_remove_if_exists(path)

	var file := FileAccess.open(path, FileAccess.WRITE)
	ReplayFileScript.write_header(
		file, "res://scenes/match/demo_match.tscn", "9f3a1c...deadbeef", -123456789012345, PackedByteArray([9, 8, 7, 6, 5])
	)
	file.close()

	var result := ReplayFileScript.read(path)
	_expect(bool(result.get("ok", false)), "a well-formed header must read back ok: %s" % [result.get("message", "")])
	_expect(
		String(result.get("scene_path", "")) == "res://scenes/match/demo_match.tscn",
		"scene_path must round-trip exactly"
	)
	_expect(
		String(result.get("snapshot_digest", "")) == "9f3a1c...deadbeef",
		"snapshot_digest must round-trip exactly"
	)
	_expect(int(result.get("rng_seed", 0)) == -123456789012345, "a negative rng_seed must round-trip exactly, as s64")
	_expect(
		(result.get("start_state", PackedByteArray()) as PackedByteArray) == PackedByteArray([9, 8, 7, 6, 5]),
		"start_state must round-trip byte for byte"
	)
	_expect((result.get("records", []) as Array).is_empty(), "a header with no records must read back with none")
	_expect(not bool(result.get("truncated", true)), "a complete file must not be reported as truncated")

	_remove_if_exists(path)


func _test_record_round_trip_multiple_types() -> void:
	var path := _temp_path("records_multi_type")
	_remove_if_exists(path)

	var stop := SimStopCommandScript.new()
	stop.player_id = 1
	stop.entity_ids = PackedInt32Array([5, 6])

	var move := SimMoveCommandScript.new()
	move.player_id = 2
	move.entity_ids = PackedInt32Array([7])
	move.target = Vector3(1.5, 0.0, -2.25)
	move.target_entity_id = 9
	move.move_mode = 1

	var build_order := SimBuildOrderCommandScript.new()
	build_order.player_id = 3
	build_order.building_id = &"ATBarracks"
	build_order.button_index = MOUSE_BUTTON_LEFT

	var file := FileAccess.open(path, FileAccess.WRITE)
	ReplayFileScript.write_header(file, "res://scenes/match/demo_match.tscn", "", 0, PackedByteArray())
	ReplayFileScript.write_record(file, 10, SimCommandCodecScript.encode(stop))
	ReplayFileScript.write_record(file, 10, SimCommandCodecScript.encode(move))
	ReplayFileScript.write_record(file, 15, SimCommandCodecScript.encode(build_order))
	file.close()

	var result := ReplayFileScript.read(path)
	_expect(bool(result.get("ok", false)), "a well-formed multi-record replay must read back ok: %s" % [result.get("message", "")])
	var records: Array = result.get("records", [])
	_expect(records.size() == 3, "every written record must come back, got %d" % records.size())
	_expect(not bool(result.get("truncated", true)), "a complete file must not be reported as truncated")

	if records.size() == 3:
		_expect(int(records[0]["tick"]) == 10 and int(records[1]["tick"]) == 10 and int(records[2]["tick"]) == 15,
			"tick must survive per record, in write order")

		var decoded_stop := SimCommandCodecScript.decode(records[0]["payload"]) as SimStopCommand
		_expect(decoded_stop != null and decoded_stop.type_id() == SimStopCommandScript.TYPE_ID, "record 0 must decode as SimStopCommand")
		_expect(decoded_stop != null and decoded_stop.entity_ids == PackedInt32Array([5, 6]), "SimStopCommand fields must survive the round trip")

		var decoded_move := SimCommandCodecScript.decode(records[1]["payload"]) as SimMoveCommand
		_expect(decoded_move != null and decoded_move.type_id() == SimMoveCommandScript.TYPE_ID, "record 1 must decode as SimMoveCommand")
		_expect(
			decoded_move != null and decoded_move.target == Vector3(1.5, 0.0, -2.25) and decoded_move.target_entity_id == 9
			and decoded_move.move_mode == 1,
			"SimMoveCommand fields must survive the round trip"
		)

		var decoded_build := SimCommandCodecScript.decode(records[2]["payload"]) as SimBuildOrderCommand
		_expect(decoded_build != null and decoded_build.type_id() == SimBuildOrderCommandScript.TYPE_ID, "record 2 must decode as SimBuildOrderCommand")
		_expect(
			decoded_build != null and decoded_build.building_id == &"ATBarracks" and decoded_build.button_index == MOUSE_BUTTON_LEFT,
			"SimBuildOrderCommand fields must survive the round trip"
		)

	_remove_if_exists(path)


## The replay's job is to preserve drain()'s order, not to re-derive it --
## see this suite's doc comment. Written with a *descending* player_id
## (5 then 2), the opposite of what SimCommandBus.drain() itself would ever
## hand out (see _drain_order() in scripts/sim/command_bus.gd, which sorts
## ascending by player_id), so a reader that accidentally re-sorted by
## player_id instead of returning file order would be caught here.
func _test_same_tick_different_players_preserve_write_order() -> void:
	var path := _temp_path("order_preserved")
	_remove_if_exists(path)

	var first := SimStopCommandScript.new()
	first.player_id = 5
	first.entity_ids = PackedInt32Array([1])

	var second := SimStopCommandScript.new()
	second.player_id = 2
	second.entity_ids = PackedInt32Array([2])

	var file := FileAccess.open(path, FileAccess.WRITE)
	ReplayFileScript.write_header(file, "res://scenes/match/demo_match.tscn", "", 0, PackedByteArray())
	ReplayFileScript.write_record(file, 20, SimCommandCodecScript.encode(first))
	ReplayFileScript.write_record(file, 20, SimCommandCodecScript.encode(second))
	file.close()

	var result := ReplayFileScript.read(path)
	var records: Array = result.get("records", [])
	_expect(records.size() == 2, "both records must come back")
	if records.size() == 2:
		var decoded_first := SimCommandCodecScript.decode(records[0]["payload"]) as SimStopCommand
		var decoded_second := SimCommandCodecScript.decode(records[1]["payload"]) as SimStopCommand
		_expect(
			decoded_first != null and decoded_first.player_id == 5,
			"the record written first (player 5) must read back first, even though its player_id is higher"
		)
		_expect(
			decoded_second != null and decoded_second.player_id == 2,
			"the record written second (player 2) must read back second"
		)

	_remove_if_exists(path)


func _test_bad_magic_fails_closed() -> void:
	var path := _temp_path("bad_magic")
	_remove_if_exists(path)

	var file := FileAccess.open(path, FileAccess.WRITE)
	file.store_buffer("XXXX".to_utf8_buffer())
	file.close()

	var result := ReplayFileScript.read(path)
	_expect(not bool(result.get("ok", true)), "a file with the wrong magic must fail closed")
	_expect(not String(result.get("message", "")).is_empty(), "a closed failure must carry a message")

	_remove_if_exists(path)


## A structurally valid file in every way except format_version -- a real,
## well-formed header block sits right behind the bad version number, so a
## reader whose version check silently no-oped would otherwise parse this
## file successfully (ok == true, zero records) instead of failing closed.
## A file that is merely too short to contain a header (magic + version and
## nothing else) would fail for the wrong reason -- a truncated header --
## and would keep "passing" this test even if the version check itself were
## deleted entirely, which is exactly the shallow-test trap to avoid here.
func _test_unknown_format_version_fails_closed() -> void:
	var path := _temp_path("bad_version")
	_remove_if_exists(path)

	var header_buffer := StreamPeerBuffer.new()
	header_buffer.big_endian = true
	var scene_path_bytes := "res://scenes/match/demo_match.tscn".to_utf8_buffer()
	header_buffer.put_u16(scene_path_bytes.size())
	header_buffer.put_data(scene_path_bytes)
	header_buffer.put_u16(0)  # empty snapshot_digest
	header_buffer.put_64(0)  # rng_seed
	header_buffer.put_u32(0)  # empty start_state
	var header_bytes := header_buffer.data_array

	var buffer := StreamPeerBuffer.new()
	buffer.big_endian = true
	buffer.put_data(ReplayFileScript.MAGIC.to_utf8_buffer())
	buffer.put_u16(9999)
	buffer.put_u32(header_bytes.size())
	buffer.put_data(header_bytes)

	var file := FileAccess.open(path, FileAccess.WRITE)
	file.store_buffer(buffer.data_array)
	file.close()

	var result := ReplayFileScript.read(path)
	_expect(
		not bool(result.get("ok", true)),
		"an unrecognized format_version must fail closed, even though everything behind it parses cleanly"
	)
	_expect(not String(result.get("message", "")).is_empty(), "a closed failure must carry a message")

	_remove_if_exists(path)


## Truncates at several offsets inside the last (third) record's own bytes
## -- inside the tick field, inside the payload_length field, and inside
## the payload itself -- rather than at a single offset, because a guard
## missing for only one of those fields would still pass a single-offset
## test. See ReplayFile._read_records()'s doc comment for the three
## get_available_bytes() checks this is proving all three of.
func _test_truncated_tail_at_several_offsets() -> void:
	var path := _temp_path("truncated_source")
	_remove_if_exists(path)

	var first := SimStopCommandScript.new()
	first.player_id = 1
	first.entity_ids = PackedInt32Array([1])

	var second := SimStopCommandScript.new()
	second.player_id = 2
	second.entity_ids = PackedInt32Array([2])

	# The third (to-be-truncated) record: a SimMoveCommand, chosen for a
	# payload large enough (well over 40 bytes) to give offsets spread
	# across all three fields room to land distinctly inside the payload.
	var third := SimMoveCommandScript.new()
	third.player_id = 3
	third.entity_ids = PackedInt32Array([3])
	third.target = Vector3(10.0, 20.0, 30.0)
	third.target_entity_id = 4
	third.move_mode = 0

	var file := FileAccess.open(path, FileAccess.WRITE)
	ReplayFileScript.write_header(file, "res://scenes/match/demo_match.tscn", "", 0, PackedByteArray())
	ReplayFileScript.write_record(file, 5, SimCommandCodecScript.encode(first))
	ReplayFileScript.write_record(file, 5, SimCommandCodecScript.encode(second))
	var prefix_length := file.get_position()
	var third_payload := SimCommandCodecScript.encode(third)
	ReplayFileScript.write_record(file, 6, third_payload)
	file.close()

	var full_bytes := FileAccess.get_file_as_bytes(path)
	var third_record_length := full_bytes.size() - prefix_length
	_expect(third_record_length == 8 + third_payload.size(), "test setup sanity: the third record must be tick(4) + payload_length(4) + payload")

	# offsets inside the tick field (0-3), inside the payload_length field
	# (4-7), just inside the payload (8), and deep inside the payload.
	var offsets := [1, 3, 4, 6, 8, 8 + third_payload.size() / 2]
	for offset in offsets:
		var truncated_path := _temp_path("truncated_at_%d" % offset)
		_remove_if_exists(truncated_path)
		var truncated_bytes := full_bytes.slice(0, prefix_length + offset)
		var truncated_file := FileAccess.open(truncated_path, FileAccess.WRITE)
		truncated_file.store_buffer(truncated_bytes)
		truncated_file.close()

		var result := ReplayFileScript.read(truncated_path)
		_expect(
			bool(result.get("ok", false)),
			"a truncated tail must still read the earlier records, not fail closed (offset %d)" % offset
		)
		var records: Array = result.get("records", [])
		_expect(
			records.size() == 2,
			"exactly the two complete records must come back when offset %d bytes of the third are present, got %d" % [offset, records.size()]
		)
		_expect(
			bool(result.get("truncated", false)),
			"truncated must be true when the file ends %d bytes into an incomplete record" % offset
		)

		_remove_if_exists(truncated_path)

	_remove_if_exists(path)


func _test_header_only_file_is_empty_replay() -> void:
	var path := _temp_path("header_only")
	_remove_if_exists(path)

	var file := FileAccess.open(path, FileAccess.WRITE)
	ReplayFileScript.write_header(file, "res://scenes/match/demo_match.tscn", "", 0, PackedByteArray())
	file.close()

	var result := ReplayFileScript.read(path)
	_expect(bool(result.get("ok", false)), "a header-only file must still read back ok")
	_expect((result.get("records", []) as Array).is_empty(), "a header-only file must read back with zero records")
	_expect(not bool(result.get("truncated", true)), "a header-only file must not be reported as truncated")

	_remove_if_exists(path)


func _test_submit_at_ignores_delay_and_drops_late() -> void:
	var bus := SimCommandBusScript.new()
	bus.input_delay_ticks = 5

	var command := SimCommandScript.new()
	command.player_id = 1
	var target := bus.submit_at(command, 42)
	_expect(target == 42, "submit_at() must schedule for exactly the tick given, not current_tick + input_delay_ticks")
	_expect(bus.drain(41).is_empty(), "nothing must be due one tick before the given target")
	var due := bus.drain(42)
	_expect(due.size() == 1 and due[0] == command, "the command must drain at exactly the absolute tick submit_at() was given")

	var late_bus := SimCommandBusScript.new()
	late_bus.input_delay_ticks = 5
	# Marks tick 10 as already drained, the same way SimCommandBus.drain()
	# does for an empty tick (see tests/sim/command_bus_run.gd's identical
	# setup for submit()'s own late-drop case).
	late_bus.drain(10)
	var late_command := SimCommandScript.new()
	late_command.player_id = 1
	var late_target := late_bus.submit_at(late_command, 10)
	_expect(late_target == 10, "submit_at() must still report the tick it was given, even when it refuses to queue it")
	_expect(
		late_bus.dropped_late_count() == 1,
		"submit_at() must drop a target tick at or before the last drained tick, exactly like submit() does"
	)
	_expect(late_bus.pending_count() == 0, "a dropped submit_at() must never enter the pending queue")
