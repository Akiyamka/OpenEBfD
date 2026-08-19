class_name SimBuildOrderCommand
extends SimCommand

## "Build order": the sidebar's left/right click on a building slot, once the
## click has already been filtered down to a production-queue mutation --
## start a fresh order, resume a paused one, pause a running one, or cancel a
## ready/paused one. Addressed to the issuing player's own BuildingController
## queue, not to any entity: today a match has exactly one BuildingController,
## always the local player's (see that class's _building_queue field), so
## there is no Node this command names -- only building_id and which mouse
## button was pressed. Named by StringName config id rather than by Node,
## since sim-zone code may never hold a Node reference -- see
## docs/architecture/network-multiplayer.md, decision 3, and the
## sim-no-node-api rule in tools/architecture_rules.toml.
##
## Deliberately absent: the two interaction-mode branches
## BuildingController.handle_building_intent() peels off before ever building
## one of these -- entering wall-line picking, and entering (or leaving) the
## interactive placement preview for an order that is already ready. Those
## change what the player's next click means, not the state of any queue, so
## they run immediately and locally, exactly like Sell/Repair -- see that
## method's doc comment. A SimBuildOrderCommand only ever reaches
## BuildingController.execute_build_order_command() for the remaining case:
## a click that mutates (or asks to mutate) the queue itself.
##
## button_index carries MOUSE_BUTTON_LEFT/MOUSE_BUTTON_RIGHT verbatim, the
## same plain-int choice SimMoveCommand.move_mode makes for
## NavConstants.MoveMode. Which concrete mutation applies -- start, resume,
## pause, cancel, or "queue is busy"/"waiting for credits" -- is recomputed by
## execute_build_order_command() from the queue as it stands on the execution
## tick, never decided here: a verdict made at click time would let two
## clients reach different outcomes once input delay is nonzero (see
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
##
## This command's branch there forwards straight to
## BuildingController.execute_build_order_command() without resolving
## an entity id first: a production-queue order names none, so there is
## nothing for EntityNodeIndex to look up.
const TYPE_ID := 6

var building_id: StringName = &""
var button_index: int = 0


func type_id() -> int:
	return TYPE_ID


## Payload order: building_id (see SimCommand._write_string_name()), then
## button_index. read_payload() below must read these back in this exact
## order.
func write_payload(buffer: StreamPeerBuffer) -> void:
	_write_string_name(buffer, building_id)
	buffer.put_32(button_index)


func read_payload(buffer: StreamPeerBuffer) -> bool:
	var id: Variant = _read_string_name(buffer)
	if id == null:
		return false
	if buffer.get_available_bytes() < 4:
		return false
	building_id = id
	button_index = buffer.get_32()
	return true
