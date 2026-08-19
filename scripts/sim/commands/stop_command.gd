class_name SimStopCommand
extends SimCommand

## "Stop": cancel movement/attack orders on a set of entities, named by their
## stable entity id (scripts/sim/entity_registry.gd) rather than by Node,
## since sim-zone code may never hold a Node reference. Issued by
## UnitCommandController._stop_selected_entities() (the entity ids are
## snapshotted from the current selection at click time) and executed by
## CommandExecutor._execute_stop() (scripts/match/command_executor.gd) on
## the tick the bus schedules it for.

## Dispatch id for CommandExecutor.execute() and, later, the wire codec.
## 1 is arbitrary -- it only has to be stable and unique among command
## types -- and is claimed here first because Stop is this slice's only
## concrete command.
const TYPE_ID := 1

var entity_ids: PackedInt32Array = PackedInt32Array()


func type_id() -> int:
	return TYPE_ID
