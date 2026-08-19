class_name SimDeployCommand
extends SimCommand

## "Deploy": the `D` key and a repeated left-click on an already-selected
## entity, toggling the MCV into its Construction Yard and toggling the
## combat-deploy units (Kindjal/Mortar/Kobra) both ways -- see
## UnitDeploymentController.try_deploy() (scripts/units/unit_deployment_controller.gd)
## for the single entry point that decides which direction applies. Named by
## stable entity id (scripts/sim/entity_registry.gd) rather than by Node,
## since sim-zone code may never hold a Node reference -- see
## docs/architecture/network-multiplayer.md, decision 3, and the
## sim-no-node-api rule in tools/architecture_rules.toml.
##
## Unlike Move and Attack, there is no raycast at issue time: Deploy has no
## target of its own, so entity_ids -- the acting selection, snapshotted
## exactly as every other command's is -- is this command's entire payload.
## Issued by UnitCommandController._deploy_selected_entities() (the D key)
## and _try_deploy() (the repeated-click path) and executed by
## CommandExecutor._execute_deploy() (scripts/match/command_executor.gd) on
## the tick the bus schedules it for. Every per-entity verdict -- is this
## entity a deploy candidate at all, and which direction applies to it right
## now -- is deliberately absent from this struct and recomputed by
## CommandExecutor against the world as it stands on the execution tick, not
## the world as it stood at the click: a check run at click time would let
## two clients reach different verdicts once input delay is nonzero (see
## SimMoveCommand's doc comment for the identical argument).

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
const TYPE_ID := 4

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
