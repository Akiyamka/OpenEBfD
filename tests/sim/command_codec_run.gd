extends "res://tests/support/suite.gd"

## Pins down scripts/sim/command_codec.gd, the wire codec for SimCommand
## (scripts/sim/commands/sim_command.gd) -- see
## docs/architecture/network-multiplayer.md, decision 1 and phase 2. Covers
## every command type's round trip, including the cases that would silently
## pass a sloppier codec (empty and multi-entity id lists, a zero
## target_entity_id, a negative player_id, float64 precision surviving the
## wire), plus every malformed-input case decode() has to fail closed on.

const SimCommandCodecScript := preload("res://scripts/sim/command_codec.gd")
const SimStopCommandScript := preload("res://scripts/sim/commands/stop_command.gd")
const SimMoveCommandScript := preload("res://scripts/sim/commands/move_command.gd")


func _initialize() -> void:
	_run_case("SimStopCommand round-trips with an empty entity_ids", _test_stop_round_trip_empty)
	_run_case("SimStopCommand round-trips with multiple entity_ids", _test_stop_round_trip_multiple)
	_run_case(
		"SimMoveCommand round-trips every field, including a nonzero target_entity_id",
		_test_move_round_trip_full
	)
	_run_case(
		"SimMoveCommand round-trips a zero target_entity_id distinctly from a nonzero one",
		_test_move_round_trip_zero_target_entity_id
	)
	_run_case(
		"encode() spends 8 bytes per target component, proving float64 rather than assuming it",
		_test_move_target_is_encoded_as_float64_not_float32
	)
	_run_case("decode() returns null on empty bytes", _test_decode_empty_bytes)
	_run_case("decode() returns null on a buffer shorter than the envelope", _test_decode_truncated_envelope)
	_run_case("decode() returns null on a buffer whose payload is truncated", _test_decode_truncated_payload)
	_run_case("decode() returns null on an unknown type id", _test_decode_unknown_type_id)
	_run_case(
		"decode() returns null when the payload leaves trailing bytes unconsumed",
		_test_decode_trailing_bytes
	)
	_run_case(
		"every concrete SimCommand under scripts/sim/commands/ is registered in the codec's table",
		_test_every_command_type_is_registered
	)
	_run_case("no two command types share a TYPE_ID", _test_no_duplicate_type_ids)
	_finish("SimCommandCodec tests")


func _test_stop_round_trip_empty() -> void:
	var command := SimStopCommandScript.new()
	command.player_id = 2
	command.entity_ids = PackedInt32Array()

	var decoded := SimCommandCodecScript.decode(SimCommandCodecScript.encode(command))
	_expect(decoded != null, "a well-formed Stop command must decode")
	_expect(decoded.type_id() == SimStopCommandScript.TYPE_ID, "decoded command must be a SimStopCommand")
	_expect(decoded.player_id == 2, "player_id must round-trip")
	_expect(
		(decoded as SimStopCommand).entity_ids == PackedInt32Array(),
		"an empty entity_ids must round-trip as empty, not as absent or malformed"
	)


func _test_stop_round_trip_multiple() -> void:
	var command := SimStopCommandScript.new()
	# player_id can legitimately be negative: PlayerData.NEUTRAL_PLAYER_ID
	# (scripts/players/player_data.gd) is -1, and it has to round-trip like
	# any other value.
	command.player_id = -1
	command.entity_ids = PackedInt32Array([3, 1, 42, 100000])

	var decoded := SimCommandCodecScript.decode(SimCommandCodecScript.encode(command)) as SimStopCommand
	_expect(decoded != null, "a well-formed Stop command must decode")
	_expect(decoded.player_id == -1, "a negative player_id must round-trip exactly")
	_expect(
		decoded.entity_ids == PackedInt32Array([3, 1, 42, 100000]),
		"entity_ids must round-trip in the exact order and values submitted"
	)


func _test_move_round_trip_full() -> void:
	var command := SimMoveCommandScript.new()
	command.player_id = 3
	command.entity_ids = PackedInt32Array([7, 8, 9])
	command.target = Vector3(12.5, -3.25, 500.0)
	command.target_entity_id = 77
	command.move_mode = 1

	var decoded := SimCommandCodecScript.decode(SimCommandCodecScript.encode(command)) as SimMoveCommand
	_expect(decoded != null, "a well-formed Move command must decode")
	_expect(decoded.type_id() == SimMoveCommandScript.TYPE_ID, "decoded command must be a SimMoveCommand")
	_expect(decoded.player_id == 3, "player_id must round-trip")
	_expect(
		decoded.entity_ids == PackedInt32Array([7, 8, 9]), "entity_ids must round-trip in order and value"
	)
	_expect(decoded.target == Vector3(12.5, -3.25, 500.0), "target must round-trip exactly")
	_expect(decoded.target_entity_id == 77, "a nonzero target_entity_id must round-trip")
	_expect(decoded.move_mode == 1, "move_mode must round-trip")


func _test_move_round_trip_zero_target_entity_id() -> void:
	var command := SimMoveCommandScript.new()
	command.player_id = 1
	command.entity_ids = PackedInt32Array([5])
	command.target = Vector3(1.0, 2.0, 3.0)
	command.target_entity_id = 0
	command.move_mode = 0

	var decoded := SimCommandCodecScript.decode(SimCommandCodecScript.encode(command)) as SimMoveCommand
	_expect(decoded != null, "a well-formed Move command must decode")
	_expect(
		decoded.target_entity_id == 0,
		"a zero target_entity_id (no clicked entity) must round-trip as 0, not be conflated with a missing field"
	)


## Proves float64 is actually on the wire rather than assuming it, but not
## by feeding target.x/y/z a value float32 cannot represent: this project
## builds Godot at its default single-precision (Vector3's own storage is
## float32), so any value assigned to a Vector3 field is already rounded to
## float32 before write_payload() ever sees it -- decoded.target == the
## rounded input would pass identically whether the codec used put_double()
## or put_float(), which proves nothing. What float32 cannot fake is the
## byte count: 3 components at 8 bytes each (float64) versus 4 (float32) is
## a 12-byte difference in the encoded payload, which is what this checks
## instead.
func _test_move_target_is_encoded_as_float64_not_float32() -> void:
	var command := SimMoveCommandScript.new()
	command.player_id = 1
	command.entity_ids = PackedInt32Array()
	command.target = Vector3(1.0, 2.0, 3.0)
	command.target_entity_id = 0
	command.move_mode = 0

	var bytes := SimCommandCodecScript.encode(command)
	# envelope (2 + 4) + entity_ids count (4, zero ids) + target (3 * 8 for
	# float64) + target_entity_id (4) + move_mode (4) = 42. Using float32 for
	# target would total 30.
	_expect(
		bytes.size() == 42,
		"encode() must spend 8 bytes per target component (float64), not 4 (float32); got %d total bytes" % bytes.size()
	)


func _test_decode_empty_bytes() -> void:
	_expect(
		SimCommandCodecScript.decode(PackedByteArray()) == null,
		"decode() must return null, never crash, on an empty buffer"
	)


func _test_decode_truncated_envelope() -> void:
	# The envelope alone is 6 bytes (u16 type_id + s32 player_id); 3 bytes
	# cannot even name a type.
	_expect(
		SimCommandCodecScript.decode(PackedByteArray([0, 1, 0])) == null,
		"decode() must return null on a buffer shorter than the envelope"
	)


func _test_decode_truncated_payload() -> void:
	# A hand-built Stop envelope (type_id 1, player_id 0) whose entity_ids
	# count prefix claims 2 ids but supplies only 1 -- the truncated-payload
	# case a hostile or corrupt frame produces.
	var buffer := StreamPeerBuffer.new()
	buffer.big_endian = true
	buffer.put_u16(SimStopCommandScript.TYPE_ID)
	buffer.put_32(0)
	buffer.put_u32(2)
	buffer.put_32(5)
	_expect(
		SimCommandCodecScript.decode(buffer.data_array) == null,
		"decode() must return null when a payload's own length prefix claims more than the buffer holds"
	)


func _test_decode_unknown_type_id() -> void:
	var buffer := StreamPeerBuffer.new()
	buffer.big_endian = true
	buffer.put_u16(9999)
	buffer.put_32(0)
	_expect(
		SimCommandCodecScript.decode(buffer.data_array) == null,
		"decode() must return null on a type id no concrete command claims"
	)


func _test_decode_trailing_bytes() -> void:
	var command := SimStopCommandScript.new()
	command.entity_ids = PackedInt32Array([1])
	var bytes := SimCommandCodecScript.encode(command)
	bytes.append(0)
	_expect(
		SimCommandCodecScript.decode(bytes) == null,
		"decode() must return null when the payload leaves unconsumed trailing bytes -- " \
		+ "a payload that does not match its declared type"
	)


## Discovers the truth instead of restating it: filters
## ProjectSettings.get_global_class_list() for scripts under
## scripts/sim/commands/ whose base is SimCommand, which is exactly the set
## of concrete command types -- no separate list to fall out of sync with
## SimCommandCodec's own hand-written table. This is what turns "someone
## added a command type and forgot to register it in the codec" from a
## silent gap into a named failure.
func _concrete_command_class_entries() -> Array:
	var entries: Array = []
	for entry in ProjectSettings.get_global_class_list():
		if String(entry.get("base", "")) != "SimCommand":
			continue
		if not String(entry.get("path", "")).begins_with("res://scripts/sim/commands/"):
			continue
		entries.append(entry)
	return entries


func _test_every_command_type_is_registered() -> void:
	var registered_paths := {}
	for script in SimCommandCodecScript._COMMAND_SCRIPTS.values():
		registered_paths[(script as Script).resource_path] = true

	var missing: Array[String] = []
	for entry in _concrete_command_class_entries():
		var path := String(entry.get("path", ""))
		if not registered_paths.has(path):
			missing.append(String(entry.get("class", path)))

	_expect(
		missing.is_empty(),
		"every SimCommand subclass under scripts/sim/commands/ must appear in SimCommandCodec's table; missing: %s" % [missing]
	)


func _test_no_duplicate_type_ids() -> void:
	# Discovers TYPE_ID directly off each concrete class, independent of
	# SimCommandCodec's own table -- a Dictionary literal with a repeated key
	# would just silently keep the last one, so the collision has to be
	# found by asking the command classes themselves, the same way a decoder
	# would be fooled by it.
	var owner_by_type_id := {}
	var collisions: Array[String] = []
	for entry in _concrete_command_class_entries():
		var script := load(String(entry.get("path", ""))) as GDScript
		var instance: SimCommand = script.new()
		var type_id := instance.type_id()
		var class_name_str := String(entry.get("class", ""))
		if owner_by_type_id.has(type_id):
			collisions.append(
				"%s and %s both claim TYPE_ID %d" % [owner_by_type_id[type_id], class_name_str, type_id]
			)
		else:
			owner_by_type_id[type_id] = class_name_str

	_expect(collisions.is_empty(), "no two command types may share a TYPE_ID; found: %s" % [collisions])
