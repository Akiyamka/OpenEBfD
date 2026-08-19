class_name SimTargetAbilityCommand
extends SimCommand

## "Target ability": the selection-targeted abilities SelectionTargetAbilityController
## arms and cancels (scripts/match/selection_target_ability_controller.gd) --
## Advanced Carryall's Pick Up/Drop Cargo today, more later, all through the
## identical definitions()/validate()/cursor_for()/execute() handler contract
## (see AdvancedCarryallAbility, scripts/match/advanced_carryall_ability.gd).
## One left click, while a mode is armed, is one of these; ability_id is what
## tells CommandExecutor which handler's execute() to call -- see
## SimCommand._write_string_name()/_read_string_name() for how a StringName
## survives the wire.
##
## Named by stable entity id (scripts/sim/entity_registry.gd) rather than by
## Node, since sim-zone code may never hold a Node reference -- see
## docs/architecture/network-multiplayer.md, decision 3, and the
## sim-no-node-api rule in tools/architecture_rules.toml. entity_ids is the
## acting selection, snapshotted at click time exactly as every other
## command's is: which entities this ability applies to is part of the
## command, not something CommandExecutor re-reads from
## UnitCommandController's live selection, which is view state and will have
## moved on by the execution tick -- see SimMoveCommand's doc comment for the
## identical argument applied to Move.
##
## Issued by UnitCommandController._execute_target_ability() and executed by
## CommandExecutor._execute_target_ability() (scripts/match/command_executor.gd)
## on the tick the bus schedules it for. target_entity_id/target_position
## mirror SimAttackCommand.target_entity_id/target exactly: the stable id of
## the entity under the cursor at click time, or 0, alongside the terrain
## position from the same two raycasts UnitCommandController's cursor preview
## already makes (_update_target_ability_cursor()) -- resolved back to a Node
## (or left unresolved, on a since-dead id) by CommandExecutor, never by this
## struct.

## Dispatch id for CommandExecutor.execute()
## (scripts/match/command_executor.gd) and SimCommandCodec
## (scripts/sim/command_codec.gd). Which ids are already claimed is recorded
## in exactly one place -- SimCommandCodec._COMMAND_SCRIPTS -- and
## tests/sim/command_codec_run.gd fails if a command type is missing from
## that table, so the next command type reads its id off that list. Each of
## these comments used to carry its own copy of the list instead, which is
## how two of them came to describe a command-type dispatch in Match that
## has not existed since CommandExecutor.execute() became the only place
## answering "which command is this".
const TYPE_ID := 5

var entity_ids: PackedInt32Array = PackedInt32Array()
var ability_id: StringName = &""
var target_entity_id: int = 0
var target_position: Vector3 = Vector3.ZERO


func type_id() -> int:
	return TYPE_ID


## Payload order: entity_ids (see SimCommand._write_entity_ids()), then
## ability_id (see SimCommand._write_string_name()), then target_entity_id,
## then target_position.x/y/z as float64 each (decision 5 -- no narrowing to
## float32 on the wire). read_payload() below must read these back in this
## exact order.
func write_payload(buffer: StreamPeerBuffer) -> void:
	_write_entity_ids(buffer, entity_ids)
	_write_string_name(buffer, ability_id)
	buffer.put_32(target_entity_id)
	buffer.put_double(target_position.x)
	buffer.put_double(target_position.y)
	buffer.put_double(target_position.z)


func read_payload(buffer: StreamPeerBuffer) -> bool:
	var ids: Variant = _read_entity_ids(buffer)
	if ids == null:
		return false
	var ability: Variant = _read_string_name(buffer)
	if ability == null:
		return false
	# target_entity_id (4) + 3 float64 target_position components (24) = 28 bytes.
	if buffer.get_available_bytes() < 28:
		return false
	entity_ids = ids
	ability_id = ability
	target_entity_id = buffer.get_32()
	target_position = Vector3(buffer.get_double(), buffer.get_double(), buffer.get_double())
	return true
