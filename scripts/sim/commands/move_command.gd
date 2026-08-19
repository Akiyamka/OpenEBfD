class_name SimMoveCommand
extends SimCommand

## "Move": the busiest player intent in the game, and the one that fans out
## the furthest -- one click here can resolve, per acting entity, to a plain
## move, a harvest order, an unload order, or (for a building) a rally point
## or an undeployment request. Named by stable entity id
## (scripts/sim/entity_registry.gd) rather than by Node, since sim-zone code
## may never hold a Node reference -- see docs/architecture/network-multiplayer.md,
## decision 3, and the sim-no-node-api rule in tools/architecture_rules.toml.
##
## Issued by UnitCommandController._command_move() (the entity ids are
## snapshotted from the current selection at click time, exactly as
## SimStopCommand's are) and executed by CommandExecutor._execute_move()
## (scripts/match/command_executor.gd) on the tick the bus schedules it for.
## Every classification decision -- who moves, who rallies, who harvests, who
## unloads, who is still immobilized by deployment -- is deliberately absent
## from this struct and recomputed by CommandExecutor against the world as it
## stands on the execution tick, not the world as it stood at the click: a
## check run at click time would let two clients reach different verdicts
## once input delay is nonzero (see UnitCommandController._command_move()'s
## doc comment).

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
const TYPE_ID := 2

var entity_ids: PackedInt32Array = PackedInt32Array()

## Where the player clicked, already resolved from screen space to a world
## position by the terrain raycast at issue time -- see SimCommand's doc
## comment for why the click-to-world resolution itself stays out of the
## command's execution (it is a view fact, not a simulation input) even
## though the resulting Vector3 travels as plain data.
var target: Vector3 = Vector3.ZERO

## The stable id of the entity under the cursor at click time, or 0 when
## nothing was there. This is what drives the unload path: CommandExecutor
## resolves it back to a Node and, if that Node still exists and accepts an
## unload from one of the acting entities, routes to command_unload() instead
## of a plain move. An id that no longer resolves by execution time (the
## entity died in between) simply falls through to plain movement -- see
## CommandExecutor._execute_move()'s comment on that path.
var target_entity_id: int = 0

## NavConstants.MoveMode (scripts/units/navigation/shared/nav_constants.gd),
## carried as a plain int rather than the enum type itself so this command
## does not need to preload a non-sim script for a constant it only ever
## passes through unexamined.
var move_mode: int = 0


func type_id() -> int:
	return TYPE_ID


## Payload order: entity_ids (see SimCommand._write_entity_ids()), then
## target.x/y/z as float64 each (decision 5 -- no narrowing to float32 on
## the wire), then target_entity_id, then move_mode. read_payload() below
## must read these back in this exact order.
func write_payload(buffer: StreamPeerBuffer) -> void:
	_write_entity_ids(buffer, entity_ids)
	buffer.put_double(target.x)
	buffer.put_double(target.y)
	buffer.put_double(target.z)
	buffer.put_32(target_entity_id)
	buffer.put_32(move_mode)


func read_payload(buffer: StreamPeerBuffer) -> bool:
	var ids: Variant = _read_entity_ids(buffer)
	if ids == null:
		return false
	# 3 float64 + 2 signed 32-bit fields = 24 + 4 + 4 bytes.
	if buffer.get_available_bytes() < 32:
		return false
	entity_ids = ids
	target = Vector3(buffer.get_double(), buffer.get_double(), buffer.get_double())
	target_entity_id = buffer.get_32()
	move_mode = buffer.get_32()
	return true
