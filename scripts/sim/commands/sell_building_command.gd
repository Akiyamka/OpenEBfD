class_name SimSellBuildingCommand
extends SimCommand

## "Sell": left-click in sell mode on one of the player's own buildings,
## refunding it and starting its sale/demolition sequence
## (BuildingSaleService, scripts/buildings/building_sale_service.gd). Named
## by stable entity id (scripts/sim/entity_registry.gd) rather than by Node,
## since sim-zone code may never hold a Node reference -- see
## docs/architecture/network-multiplayer.md, decision 3, and the
## sim-no-node-api rule in tools/architecture_rules.toml.
##
## One click names one building, so entity_id is this command's entire
## payload -- unlike Move/Attack/Deploy's entity_ids, the sell-mode raycast
## (BuildingController._try_sell_building()) can only ever resolve to a
## single building under the cursor, never a live selection. Entering or
## leaving sell mode itself is a local view-state change and never reaches
## this command -- it changes what the player's next click means, not the
## state of the world -- exactly the reasoning
## SimBuildOrderCommand's doc comment states for its own two mode branches,
## which in turn cites BuildingController.handle_building_intent()'s doc
## comment.
##
## Issued by BuildingController._try_sell_building() (the entity id is
## resolved from the raycast at click time, the same way SimStopCommand's
## and SimMoveCommand's entity ids are snapshotted from a live selection) and
## executed by BuildingController.execute_sell_building_command()
## (scripts/buildings/building_controller.gd), reached through
## CommandExecutor.execute()'s dispatch (scripts/match/command_executor.gd)
## on the tick the bus schedules it for. Every verdict -- is a sale already
## in progress, does this building belong to the local player -- is
## deliberately absent from this struct and recomputed at execution time
## against the world as it stands then, not the world as it stood at the
## click: a check run at click time would let two clients reach different
## verdicts once input delay is nonzero (see SimMoveCommand's doc comment
## for the identical argument).

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
const TYPE_ID := 9

var entity_id: int = 0


func type_id() -> int:
	return TYPE_ID


## Payload is just entity_id, as a signed 32-bit value.
func write_payload(buffer: StreamPeerBuffer) -> void:
	buffer.put_32(entity_id)


func read_payload(buffer: StreamPeerBuffer) -> bool:
	if buffer.get_available_bytes() < 4:
		return false
	entity_id = buffer.get_32()
	return true
