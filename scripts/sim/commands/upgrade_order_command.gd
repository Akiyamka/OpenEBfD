class_name SimUpgradeOrderCommand
extends SimCommand

## "Upgrade order": the sidebar's left/right click on an upgrade slot -- start
## a fresh global-type or refinery-dock order, resume a paused one, pause a
## running one, or cancel a ready/paused one. Addressed to the issuing
## player's own BuildingUpgradeController queue, not to any entity: today a
## match has exactly one BuildingUpgradeController, always the local player's
## (see that class's _upgrade_queue field), so there is no Node this command
## names -- only upgrade_id (a building config id either way -- see
## BuildingUpgradeController.handle_upgrade_intent()'s doc comment on the two
## upgrade shapes sharing one queue) and which mouse button was pressed. Named
## by StringName config id rather than by Node, since sim-zone code may never
## hold a Node reference -- see docs/architecture/network-multiplayer.md,
## decision 3, and the sim-no-node-api rule in tools/architecture_rules.toml.
##
## Unlike BuildingController's build order, BuildingUpgradeController has no
## interaction-mode branch to peel off: neither upgrade shape opens a
## placement preview of its own (a global-type upgrade applies instantly to
## every owned building of that type; a refinery-dock upgrade advances an
## already-owned refinery's built-in dock state), so every left/right click on
## an upgrade slot becomes one of these.
##
## button_index carries MOUSE_BUTTON_LEFT/MOUSE_BUTTON_RIGHT verbatim, the
## same plain-int choice SimMoveCommand.move_mode makes for
## NavConstants.MoveMode. Which concrete mutation applies -- start (and, for a
## dock, which eligible refinery it binds to), resume, pause, or cancel -- is
## recomputed by execute_upgrade_order_command() from the queue (and, for a
## dock, the owned refineries) as they stand on the execution tick, never
## decided here: a verdict made at click time would let two clients reach
## different outcomes once input delay is nonzero (see SimMoveCommand's doc
## comment for the identical argument).

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
## BuildingUpgradeController.execute_upgrade_order_command() without
## resolving an entity id first: an upgrade order names none, so there is
## nothing for EntityNodeIndex to look up.
const TYPE_ID := 8

var upgrade_id: StringName = &""
var button_index: int = 0


func type_id() -> int:
	return TYPE_ID


## Payload order: upgrade_id (see SimCommand._write_string_name()), then
## button_index. read_payload() below must read these back in this exact
## order.
func write_payload(buffer: StreamPeerBuffer) -> void:
	_write_string_name(buffer, upgrade_id)
	buffer.put_32(button_index)


func read_payload(buffer: StreamPeerBuffer) -> bool:
	var id: Variant = _read_string_name(buffer)
	if id == null:
		return false
	if buffer.get_available_bytes() < 4:
		return false
	upgrade_id = id
	button_index = buffer.get_32()
	return true
