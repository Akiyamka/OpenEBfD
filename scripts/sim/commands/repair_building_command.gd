class_name SimRepairBuildingCommand
extends SimCommand

## "Repair": right-click in repair mode on one of the player's own damaged
## buildings, toggling its repair state -- start repairing an idle damaged
## building, or cancel a repair already in progress. Named by stable entity
## id (scripts/sim/entity_registry.gd) rather than by Node, since sim-zone
## code may never hold a Node reference -- see
## docs/architecture/network-multiplayer.md, decision 3, and the
## sim-no-node-api rule in tools/architecture_rules.toml.
##
## One click names one building, so entity_id is this command's entire
## payload -- unlike Move/Attack/Deploy's entity_ids, the repair-mode raycast
## (BuildingController._try_toggle_building_repair()) can only ever resolve
## to a single building under the cursor, never a live selection. Entering
## or leaving repair mode itself is a local view-state change and never
## reaches this command -- see SimSellBuildingCommand's doc comment for the
## identical reasoning, which applies here unchanged.
##
## Deliberately absent: which direction the toggle goes. is_repairing must
## be read off the building at execution time, never decided at click time --
## two clicks landing on the same tick then toggle twice, which is what the
## player actually did, instead of both clicks racing to read the same
## pre-click state and canceling each other out. This is the same
## "recompute the verdict on the execution tick" discipline
## SimMoveCommand's and SimAttackCommand's doc comments state for their own
## per-entity verdicts, applied here to a single boolean instead of a
## movement/attack classification.
##
## Issued by BuildingController._try_toggle_building_repair() (the entity id
## is resolved from the raycast at click time) and executed by
## BuildingController.execute_repair_building_command()
## (scripts/buildings/building_controller.gd), reached through
## CommandExecutor.execute()'s dispatch (scripts/match/command_executor.gd)
## on the tick the bus schedules it for.

## Dispatch id for CommandExecutor.execute() and SimCommandCodec
## (scripts/sim/command_codec.gd). 1 is SimStopCommand's, 2 is
## SimMoveCommand's, 3 is SimAttackCommand's, 4 is SimDeployCommand's, 5 is
## SimTargetAbilityCommand's, 6 is SimBuildOrderCommand's, 7 is
## SimUnitOrderCommand's, 8 is SimUpgradeOrderCommand's, 9 is
## SimSellBuildingCommand's; this is the next one claimed.
const TYPE_ID := 10

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
