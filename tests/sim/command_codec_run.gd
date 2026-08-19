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
const SimAttackCommandScript := preload("res://scripts/sim/commands/attack_command.gd")
const SimDeployCommandScript := preload("res://scripts/sim/commands/deploy_command.gd")
const SimTargetAbilityCommandScript := preload("res://scripts/sim/commands/target_ability_command.gd")
const SimBuildOrderCommandScript := preload("res://scripts/sim/commands/build_order_command.gd")
const SimUnitOrderCommandScript := preload("res://scripts/sim/commands/unit_order_command.gd")
const SimUpgradeOrderCommandScript := preload("res://scripts/sim/commands/upgrade_order_command.gd")
const SimSellBuildingCommandScript := preload("res://scripts/sim/commands/sell_building_command.gd")
const SimRepairBuildingCommandScript := preload("res://scripts/sim/commands/repair_building_command.gd")
const SimPlaceBuildingCommandScript := preload("res://scripts/sim/commands/place_building_command.gd")


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
	_run_case(
		"SimAttackCommand round-trips a target-specific attack, including a nonzero target_entity_id",
		_test_attack_round_trip_with_target
	)
	_run_case(
		"SimAttackCommand round-trips an attack-ground order with target_entity_id 0",
		_test_attack_round_trip_ground_only
	)
	_run_case("SimDeployCommand round-trips with an empty entity_ids", _test_deploy_round_trip_empty)
	_run_case("SimDeployCommand round-trips with multiple entity_ids", _test_deploy_round_trip_multiple)
	_run_case(
		"SimTargetAbilityCommand round-trips every field, including a nonzero target_entity_id",
		_test_target_ability_round_trip_full
	)
	_run_case(
		"SimTargetAbilityCommand round-trips an ASCII ability id byte-for-byte",
		_test_target_ability_round_trip_ascii_id
	)
	_run_case(
		"SimTargetAbilityCommand round-trips an ability id containing a non-ASCII character",
		_test_target_ability_round_trip_non_ascii_id
	)
	_run_case(
		"SimTargetAbilityCommand round-trips an empty ability id",
		_test_target_ability_round_trip_empty_id
	)
	_run_case(
		"encode() spends 1 byte per UTF-8 code unit of ability_id, not per character",
		_test_target_ability_id_is_encoded_as_utf8_byte_length
	)
	_run_case(
		"SimBuildOrderCommand round-trips a left-click building_id and button_index",
		_test_build_order_round_trip_left
	)
	_run_case(
		"SimBuildOrderCommand round-trips a right-click button_index",
		_test_build_order_round_trip_right
	)
	_run_case(
		"SimUnitOrderCommand round-trips unit_id, button_index and a multi-unit quantity",
		_test_unit_order_round_trip_quantity
	)
	_run_case(
		"SimUpgradeOrderCommand round-trips upgrade_id and button_index",
		_test_upgrade_order_round_trip
	)
	_run_case(
		"SimSellBuildingCommand round-trips type_id, player_id and entity_id",
		_test_sell_building_round_trip
	)
	_run_case(
		"SimRepairBuildingCommand round-trips type_id, player_id and entity_id",
		_test_repair_building_round_trip
	)
	_run_case(
		"SimPlaceBuildingCommand round-trips building_id, nav_cell and rotation_quarter_turns",
		_test_place_building_round_trip
	)
	_run_case(
		"SimPlaceBuildingCommand round-trips a nav_cell with negative components",
		_test_place_building_round_trip_negative_cell
	)
	_run_case("decode() returns null on empty bytes", _test_decode_empty_bytes)
	_run_case("decode() returns null on a buffer shorter than the envelope", _test_decode_truncated_envelope)
	_run_case("decode() returns null on a buffer whose payload is truncated", _test_decode_truncated_payload)
	_run_case(
		"decode() returns null when an ability id's length prefix claims more bytes than the buffer holds",
		_test_decode_truncated_ability_id
	)
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


## The with-target shape: a click that landed on a live entity, so
## target_entity_id is nonzero alongside the plain-data target position
## recorded at issue time (see SimAttackCommand.target's doc comment on why
## that position still travels even when a target entity was found).
func _test_attack_round_trip_with_target() -> void:
	var command := SimAttackCommandScript.new()
	command.player_id = 4
	command.entity_ids = PackedInt32Array([11, 22])
	command.target = Vector3(6.5, 0.0, -9.25)
	command.target_entity_id = 55

	var decoded := SimCommandCodecScript.decode(SimCommandCodecScript.encode(command)) as SimAttackCommand
	_expect(decoded != null, "a well-formed target-specific Attack command must decode")
	_expect(decoded.type_id() == SimAttackCommandScript.TYPE_ID, "decoded command must be a SimAttackCommand")
	_expect(decoded.player_id == 4, "player_id must round-trip")
	_expect(
		decoded.entity_ids == PackedInt32Array([11, 22]), "entity_ids must round-trip in order and value"
	)
	_expect(decoded.target == Vector3(6.5, 0.0, -9.25), "target must round-trip exactly")
	_expect(decoded.target_entity_id == 55, "a nonzero target_entity_id must round-trip")


## The ground-only shape: a Ctrl-click on open terrain, where target_entity_id
## must round-trip as 0 -- attack-ground, not "no clicked entity field at
## all" -- exactly as SimMoveCommand's zero target_entity_id case pins down.
func _test_attack_round_trip_ground_only() -> void:
	var command := SimAttackCommandScript.new()
	command.player_id = 1
	command.entity_ids = PackedInt32Array([7])
	command.target = Vector3(12.0, 0.0, 14.0)
	command.target_entity_id = 0

	var decoded := SimCommandCodecScript.decode(SimCommandCodecScript.encode(command)) as SimAttackCommand
	_expect(decoded != null, "a well-formed attack-ground command must decode")
	_expect(
		decoded.entity_ids == PackedInt32Array([7]), "entity_ids must round-trip in order and value"
	)
	_expect(decoded.target == Vector3(12.0, 0.0, 14.0), "target must round-trip exactly")
	_expect(
		decoded.target_entity_id == 0,
		"a zero target_entity_id (attack-ground) must round-trip as 0, not be conflated with a missing field"
	)


func _test_deploy_round_trip_empty() -> void:
	var command := SimDeployCommandScript.new()
	command.player_id = 2
	command.entity_ids = PackedInt32Array()

	var decoded := SimCommandCodecScript.decode(SimCommandCodecScript.encode(command))
	_expect(decoded != null, "a well-formed Deploy command must decode")
	_expect(decoded.type_id() == SimDeployCommandScript.TYPE_ID, "decoded command must be a SimDeployCommand")
	_expect(decoded.player_id == 2, "player_id must round-trip")
	_expect(
		(decoded as SimDeployCommand).entity_ids == PackedInt32Array(),
		"an empty entity_ids must round-trip as empty, not as absent or malformed"
	)


func _test_deploy_round_trip_multiple() -> void:
	var command := SimDeployCommandScript.new()
	# player_id can legitimately be negative: PlayerData.NEUTRAL_PLAYER_ID
	# (scripts/players/player_data.gd) is -1, and it has to round-trip like
	# any other value.
	command.player_id = -1
	command.entity_ids = PackedInt32Array([3, 1, 42, 100000])

	var decoded := SimCommandCodecScript.decode(SimCommandCodecScript.encode(command)) as SimDeployCommand
	_expect(decoded != null, "a well-formed Deploy command must decode")
	_expect(decoded.player_id == -1, "a negative player_id must round-trip exactly")
	_expect(
		decoded.entity_ids == PackedInt32Array([3, 1, 42, 100000]),
		"entity_ids must round-trip in the exact order and values submitted"
	)


func _test_target_ability_round_trip_full() -> void:
	var command := SimTargetAbilityCommandScript.new()
	command.player_id = 5
	command.entity_ids = PackedInt32Array([9, 4])
	command.ability_id = &"pickup"
	command.target_entity_id = 33
	command.target_position = Vector3(1.5, -2.25, 300.0)

	var decoded := SimCommandCodecScript.decode(
		SimCommandCodecScript.encode(command)
	) as SimTargetAbilityCommand
	_expect(decoded != null, "a well-formed target-ability command must decode")
	_expect(
		decoded.type_id() == SimTargetAbilityCommandScript.TYPE_ID,
		"decoded command must be a SimTargetAbilityCommand"
	)
	_expect(decoded.player_id == 5, "player_id must round-trip")
	_expect(
		decoded.entity_ids == PackedInt32Array([9, 4]), "entity_ids must round-trip in order and value"
	)
	_expect(decoded.ability_id == &"pickup", "ability_id must round-trip")
	_expect(decoded.target_entity_id == 33, "a nonzero target_entity_id must round-trip")
	_expect(
		decoded.target_position == Vector3(1.5, -2.25, 300.0), "target_position must round-trip exactly"
	)


## Pins down the plain-ASCII case on its own, distinct from the full-field
## round trip above, so a codec that mishandled non-ASCII specifically (the
## two cases beneath this one) could not hide behind an otherwise-passing
## ASCII test.
func _test_target_ability_round_trip_ascii_id() -> void:
	var command := SimTargetAbilityCommandScript.new()
	command.entity_ids = PackedInt32Array([1])
	command.ability_id = &"drop"
	command.target_entity_id = 0
	command.target_position = Vector3.ZERO

	var decoded := SimCommandCodecScript.decode(
		SimCommandCodecScript.encode(command)
	) as SimTargetAbilityCommand
	_expect(decoded != null, "a well-formed ASCII ability id must decode")
	_expect(decoded.ability_id == &"drop", "a plain-ASCII ability_id must round-trip byte-for-byte")


## The case a hand-rolled string encoder that counts characters instead of
## UTF-8 bytes gets wrong: "café" is 4 characters but 5 bytes (the "é" is a
## two-byte UTF-8 sequence), so a length prefix that used
## String.length() instead of the byte count would misplace the read cursor
## for every field this command's payload writes after ability_id.
func _test_target_ability_round_trip_non_ascii_id() -> void:
	var command := SimTargetAbilityCommandScript.new()
	command.entity_ids = PackedInt32Array([7, 8])
	command.ability_id = StringName("café✓")
	command.target_entity_id = 12
	command.target_position = Vector3(4.0, 5.0, 6.0)

	var decoded := SimCommandCodecScript.decode(
		SimCommandCodecScript.encode(command)
	) as SimTargetAbilityCommand
	_expect(decoded != null, "a well-formed non-ASCII ability id must decode")
	_expect(
		decoded.ability_id == StringName("café✓"),
		"a non-ASCII ability_id must round-trip exactly, not be mangled or truncated"
	)
	_expect(
		decoded.target_entity_id == 12 and decoded.target_position == Vector3(4.0, 5.0, 6.0),
		"fields written after a non-ASCII ability_id must still land at the right offset"
	)


## The other case a hand-rolled string encoder gets wrong: a zero-length
## payload is not the same as a missing/malformed field, and must round-trip
## as the empty StringName, not null and not a decode failure.
func _test_target_ability_round_trip_empty_id() -> void:
	var command := SimTargetAbilityCommandScript.new()
	command.entity_ids = PackedInt32Array()
	command.ability_id = &""
	command.target_entity_id = 0
	command.target_position = Vector3.ZERO

	var decoded := SimCommandCodecScript.decode(
		SimCommandCodecScript.encode(command)
	) as SimTargetAbilityCommand
	_expect(decoded != null, "a well-formed empty ability id must decode, not fail closed")
	_expect(
		decoded.ability_id == &"",
		"an empty ability_id must round-trip as empty, not be conflated with a missing field"
	)


## Proves the length prefix is a byte count, not a character count, the same
## way _test_move_target_is_encoded_as_float64_not_float32() proves float64 by
## byte count rather than by value: "café" round-tripping correctly (the test
## above) would also pass a codec that happened to store 4 UTF-16 code units
## instead of 5 UTF-8 bytes, if get_string_from_utf8() silently tolerated the
## mismatch. Checking the actual encoded byte count directly does not depend
## on that tolerance.
func _test_target_ability_id_is_encoded_as_utf8_byte_length() -> void:
	var command := SimTargetAbilityCommandScript.new()
	command.entity_ids = PackedInt32Array()
	command.ability_id = StringName("café")
	command.target_entity_id = 0
	command.target_position = Vector3.ZERO

	var bytes := SimCommandCodecScript.encode(command)
	# envelope (2 + 4) + entity_ids count (4, zero ids) + ability_id length
	# prefix (4) + ability_id bytes (5, UTF-8 -- "café" is 4 characters but a
	# 2-byte UTF-8 sequence for "é" makes 5 bytes) + target_entity_id (4) +
	# target_position (3 * 8 for float64) = 47.
	_expect(
		bytes.size() == 47,
		"encode() must spend one byte per UTF-8 byte of ability_id, not per character; got %d total bytes" % bytes.size()
	)


func _test_build_order_round_trip_left() -> void:
	var command := SimBuildOrderCommandScript.new()
	command.player_id = 1
	command.building_id = &"ATBarracks"
	command.button_index = MOUSE_BUTTON_LEFT

	var decoded := SimCommandCodecScript.decode(
		SimCommandCodecScript.encode(command)
	) as SimBuildOrderCommand
	_expect(decoded != null, "a well-formed build-order command must decode")
	_expect(decoded.type_id() == SimBuildOrderCommandScript.TYPE_ID, "decoded command must be a SimBuildOrderCommand")
	_expect(decoded.player_id == 1, "player_id must round-trip")
	_expect(decoded.building_id == &"ATBarracks", "building_id must round-trip")
	_expect(decoded.button_index == MOUSE_BUTTON_LEFT, "a left-click button_index must round-trip")


## Distinct from the left-click case above so a codec that hard-coded
## MOUSE_BUTTON_LEFT instead of actually writing the field could not hide
## behind an otherwise-passing round trip.
func _test_build_order_round_trip_right() -> void:
	var command := SimBuildOrderCommandScript.new()
	command.player_id = 2
	command.building_id = &"ATWall"
	command.button_index = MOUSE_BUTTON_RIGHT

	var decoded := SimCommandCodecScript.decode(
		SimCommandCodecScript.encode(command)
	) as SimBuildOrderCommand
	_expect(decoded != null, "a well-formed build-order command must decode")
	_expect(decoded.building_id == &"ATWall", "building_id must round-trip")
	_expect(decoded.button_index == MOUSE_BUTTON_RIGHT, "a right-click button_index must round-trip")


func _test_unit_order_round_trip_quantity() -> void:
	var command := SimUnitOrderCommandScript.new()
	command.player_id = 3
	command.unit_id = &"ATInfantry"
	command.button_index = MOUSE_BUTTON_LEFT
	command.quantity = 11

	var decoded := SimCommandCodecScript.decode(
		SimCommandCodecScript.encode(command)
	) as SimUnitOrderCommand
	_expect(decoded != null, "a well-formed unit-order command must decode")
	_expect(decoded.type_id() == SimUnitOrderCommandScript.TYPE_ID, "decoded command must be a SimUnitOrderCommand")
	_expect(decoded.player_id == 3, "player_id must round-trip")
	_expect(decoded.unit_id == &"ATInfantry", "unit_id must round-trip")
	_expect(decoded.button_index == MOUSE_BUTTON_LEFT, "button_index must round-trip")
	_expect(decoded.quantity == 11, "a shift-click quantity greater than one must round-trip exactly")


func _test_upgrade_order_round_trip() -> void:
	var command := SimUpgradeOrderCommandScript.new()
	command.player_id = 4
	command.upgrade_id = &"ATRefineryDock"
	command.button_index = MOUSE_BUTTON_RIGHT

	var decoded := SimCommandCodecScript.decode(
		SimCommandCodecScript.encode(command)
	) as SimUpgradeOrderCommand
	_expect(decoded != null, "a well-formed upgrade-order command must decode")
	_expect(decoded.type_id() == SimUpgradeOrderCommandScript.TYPE_ID, "decoded command must be a SimUpgradeOrderCommand")
	_expect(decoded.player_id == 4, "player_id must round-trip")
	_expect(decoded.upgrade_id == &"ATRefineryDock", "upgrade_id must round-trip")
	_expect(decoded.button_index == MOUSE_BUTTON_RIGHT, "button_index must round-trip")


func _test_sell_building_round_trip() -> void:
	var command := SimSellBuildingCommandScript.new()
	command.player_id = 2
	command.entity_id = 17

	var decoded := SimCommandCodecScript.decode(
		SimCommandCodecScript.encode(command)
	) as SimSellBuildingCommand
	_expect(decoded != null, "a well-formed sell-building command must decode")
	_expect(decoded.type_id() == SimSellBuildingCommandScript.TYPE_ID, "decoded command must be a SimSellBuildingCommand")
	_expect(decoded.player_id == 2, "player_id must round-trip")
	_expect(decoded.entity_id == 17, "entity_id must round-trip")


func _test_repair_building_round_trip() -> void:
	var command := SimRepairBuildingCommandScript.new()
	command.player_id = 3
	command.entity_id = 42

	var decoded := SimCommandCodecScript.decode(
		SimCommandCodecScript.encode(command)
	) as SimRepairBuildingCommand
	_expect(decoded != null, "a well-formed repair-building command must decode")
	_expect(decoded.type_id() == SimRepairBuildingCommandScript.TYPE_ID, "decoded command must be a SimRepairBuildingCommand")
	_expect(decoded.player_id == 3, "player_id must round-trip")
	_expect(decoded.entity_id == 42, "entity_id must round-trip")


func _test_place_building_round_trip() -> void:
	var command := SimPlaceBuildingCommandScript.new()
	command.player_id = 1
	command.building_id = &"ATBarracks"
	command.nav_cell = Vector2i(12, 34)
	command.rotation_quarter_turns = 3

	var decoded := SimCommandCodecScript.decode(
		SimCommandCodecScript.encode(command)
	) as SimPlaceBuildingCommand
	_expect(decoded != null, "a well-formed place-building command must decode")
	_expect(decoded.type_id() == SimPlaceBuildingCommandScript.TYPE_ID, "decoded command must be a SimPlaceBuildingCommand")
	_expect(decoded.player_id == 1, "player_id must round-trip")
	_expect(decoded.building_id == &"ATBarracks", "building_id must round-trip")
	_expect(decoded.nav_cell == Vector2i(12, 34), "nav_cell must round-trip exactly")
	_expect(decoded.rotation_quarter_turns == 3, "rotation_quarter_turns must round-trip")


## Distinct from the case above so a codec that wrote nav_cell's components as
## unsigned values could not hide behind an otherwise-passing round trip: a
## clicked cell west or north of the nav-grid origin is ordinary, not an edge
## case the wire format gets to assume away.
func _test_place_building_round_trip_negative_cell() -> void:
	var command := SimPlaceBuildingCommandScript.new()
	command.player_id = 2
	command.building_id = &"ATWall"
	command.nav_cell = Vector2i(-5, -1)
	command.rotation_quarter_turns = 0

	var decoded := SimCommandCodecScript.decode(
		SimCommandCodecScript.encode(command)
	) as SimPlaceBuildingCommand
	_expect(decoded != null, "a well-formed place-building command with a negative cell must decode")
	_expect(decoded.nav_cell == Vector2i(-5, -1), "a nav_cell with negative components must round-trip exactly")


func _test_decode_truncated_ability_id() -> void:
	# A hand-built target-ability envelope (entity_ids empty) whose ability_id
	# length prefix claims 10 bytes but supplies none.
	var buffer := StreamPeerBuffer.new()
	buffer.big_endian = true
	buffer.put_u16(SimTargetAbilityCommandScript.TYPE_ID)
	buffer.put_32(0)
	buffer.put_u32(0)
	buffer.put_u32(10)
	_expect(
		SimCommandCodecScript.decode(buffer.data_array) == null,
		"decode() must return null when an ability id's length prefix claims more than the buffer holds"
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
