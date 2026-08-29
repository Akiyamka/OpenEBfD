class_name SimUnitOrderCommand
extends SimCommand

## "Unit order": the sidebar's left/right click on a unit slot -- add
## quantity units to a production-building type's queue, resume a paused
## order, pause a running one, or remove queued units and possibly cancel the
## active one, with a partial refund. Addressed to the command player through
## UnitProductionSystem's player-keyed state, not to any entity: Match still
## has one local UnitRosterController, but it only renders local outcomes, so
## there is no Node this command names -- only unit_id, which
## mouse button was pressed, and quantity. Named by StringName config id
## rather than by Node, since sim-zone code may never hold a Node reference --
## see docs/architecture/network-multiplayer.md, decision 3, and the
## sim-no-node-api rule in tools/architecture_rules.toml.
##
## Unlike BuildingController's build order, UnitRosterController has no
## interaction-mode branch to peel off: a unit order never opens a placement
## preview or a line-picking mode of its own (a finished unit simply spawns),
## so every left/right click on a unit slot becomes one of these -- see
## UnitRosterController.handle_unit_intent()'s doc comment.
##
## button_index carries MOUSE_BUTTON_LEFT/MOUSE_BUTTON_RIGHT verbatim, the
## same plain-int choice SimMoveCommand.move_mode makes for
## NavConstants.MoveMode. Which concrete mutation applies -- add to the queue,
## resume, pause, or remove-with-refund -- and how much of `quantity` a
## capacity-limited queue actually accepts, is recomputed by
## execute_unit_order_command() from the queue as it stands on the execution
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
## UnitRosterController.execute_unit_order_command() without resolving
## an entity id first: a production-queue order names none, so there is
## nothing for EntityNodeIndex to look up.
const TYPE_ID := 7

var unit_id: StringName = &""
var button_index: int = 0
var quantity: int = 1


func type_id() -> int:
	return TYPE_ID


## Payload order: unit_id (see SimCommand._write_string_name()), then
## button_index, then quantity. read_payload() below must read these back in
## this exact order.
func write_payload(buffer: StreamPeerBuffer) -> void:
	_write_string_name(buffer, unit_id)
	buffer.put_32(button_index)
	buffer.put_32(quantity)


func read_payload(buffer: StreamPeerBuffer) -> bool:
	var id: Variant = _read_string_name(buffer)
	if id == null:
		return false
	if buffer.get_available_bytes() < 8:
		return false
	unit_id = id
	button_index = buffer.get_32()
	quantity = buffer.get_32()
	return true
