class_name SimAttackCommand
extends SimCommand

## "Attack": right-click-on-an-enemy and Ctrl-click-on-the-ground are the same
## player intent with and without a target entity under the cursor, so this is
## one command type distinguished by whether target_entity_id is nonzero,
## the same way SimMoveCommand folds plain movement, harvesting and unloading
## into itself instead of growing a command type per branch. Named by stable
## entity id (scripts/sim/entity_registry.gd) rather than by Node, since
## sim-zone code may never hold a Node reference -- see
## docs/architecture/network-multiplayer.md, decision 3, and the
## sim-no-node-api rule in tools/architecture_rules.toml.
##
## Issued by UnitCommandController._issue_attack_order() (the entity ids are
## snapshotted from the current selection at click time, exactly as
## SimStopCommand's and SimMoveCommand's are) and executed by
## CommandExecutor._execute_attack() (scripts/match/command_executor.gd) on
## the tick the bus schedules it for. Every per-entity verdict -- can this
## entity accept an attack order against this target right now, is it
## mid-deployment-transition -- is deliberately absent from this struct and
## recomputed by CommandExecutor against the world as it stands on the
## execution tick, not the world as it stood at the click: a check run at
## click time would let two clients reach different verdicts once input delay
## is nonzero (see SimMoveCommand's doc comment for the identical argument).

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
const TYPE_ID := 3

var entity_ids: PackedInt32Array = PackedInt32Array()

## The stable id of the entity under the cursor at click time, or 0 for an
## explicit attack-ground order (Ctrl-click on open terrain). A nonzero id
## that no longer resolves by execution time (the target died in between)
## falls through to an attack-ground order at `target` instead of being
## dropped -- see CommandExecutor._execute_attack()'s comment on that path.
## This mirrors SimMoveCommand.target_entity_id's own dead-id fallback
## exactly, for the same reason: every client must resolve a target that died
## before this tick the same way, and "silently do nothing" is not the
## behaviour a player watching their target die mid-flight would expect from
## the rest of this codebase.
var target_entity_id: int = 0

## Where to attack when target_entity_id is 0, and where to fall back to if
## target_entity_id stops resolving -- already turned from screen space into
## a world position at issue time (the entity-hit raycast's own position when
## a target entity was clicked, the terrain raycast's when it was not, see
## UnitCommandController._command_at()), the same reasoning as
## SimMoveCommand.target's doc comment.
var target: Vector3 = Vector3.ZERO


func type_id() -> int:
	return TYPE_ID


## Payload order: entity_ids (see SimCommand._write_entity_ids()), then
## target.x/y/z as float64 each (decision 5 -- no narrowing to float32 on the
## wire), then target_entity_id. read_payload() below must read these back in
## this exact order.
func write_payload(buffer: StreamPeerBuffer) -> void:
	_write_entity_ids(buffer, entity_ids)
	buffer.put_double(target.x)
	buffer.put_double(target.y)
	buffer.put_double(target.z)
	buffer.put_32(target_entity_id)


func read_payload(buffer: StreamPeerBuffer) -> bool:
	var ids: Variant = _read_entity_ids(buffer)
	if ids == null:
		return false
	# 3 float64 + 1 signed 32-bit field = 24 + 4 bytes.
	if buffer.get_available_bytes() < 28:
		return false
	entity_ids = ids
	target = Vector3(buffer.get_double(), buffer.get_double(), buffer.get_double())
	target_entity_id = buffer.get_32()
	return true
