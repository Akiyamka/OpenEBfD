class_name SimStopCommand
extends SimCommand

## "Stop": cancel movement/attack orders on a set of entities, named by their
## stable entity id (scripts/sim/entity_registry.gd) rather than by Node,
## since sim-zone code may never hold a Node reference. Issued by
## UnitCommandController._stop_selected_entities() (the entity ids are
## snapshotted from the current selection at click time) and executed by
## CommandExecutor._execute_stop() (scripts/match/command_executor.gd) on
## the tick the bus schedules it for.

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
##
## 1 is arbitrary -- an id only has to be stable and unique among command
## types -- and is claimed first because Stop was the first concrete
## command this phase added.
const TYPE_ID := 1

var entity_ids: PackedInt32Array = PackedInt32Array()


func type_id() -> int:
	return TYPE_ID


## Payload is just entity_ids -- see SimCommand._write_entity_ids() for the
## shared count-prefixed layout every entity-id-carrying command uses.
func write_payload(buffer: StreamPeerBuffer) -> void:
	_write_entity_ids(buffer, entity_ids)


func read_payload(buffer: StreamPeerBuffer) -> bool:
	var ids: Variant = _read_entity_ids(buffer)
	if ids == null:
		return false
	entity_ids = ids
	return true
