class_name SimPlaceBuildingCommand
extends SimCommand

## "Place": the left click that drops a ready building order onto the map,
## once BuildingController._begin_ready_building_placement() has already put
## the interactive preview up. Named by stable building_id (the order's own
## identity) plus the clicked nav cell and the drag-rotation the player chose
## -- not by Node, since sim-zone code may never hold a Node reference -- see
## docs/architecture/network-multiplayer.md, decision 3, and the
## sim-no-node-api rule in tools/architecture_rules.toml. Not by entity id
## either: there is no entity yet, that is what this command creates.
##
## All three fields are player input, never a verdict: whether the cell is
## actually buildable is recomputed at execution time against the world as it
## stands then, by BuildingPlacement -- the one shared implementation of
## every "can this go here" check -- exactly the reasoning every other
## command's doc comment gives for keeping verdicts out of the struct (see
## SimMoveCommand's doc comment for the identical argument).
##
## - nav_cell is the click, already resolved from screen space to a grid cell
##   by the local raycast at issue time
##   (BuildingPlacement.hover_cell_from_pointer()) -- the same treatment
##   SimMoveCommand.target gets from its own raycast, and _write_cell()'s doc
##   comment (scripts/sim/commands/sim_command.gd) explains why a
##   view-resolved position may travel as plain data even though resolving it
##   stays out of the sim.
## - rotation_quarter_turns is PlacementPointerGesture's drag-rotation result
##   (scripts/buildings/placement_pointer_gesture.gd), read off
##   BuildingPlacement.rotation_quarter_turns() at the same click.
## - building_id says what the player was placing. Every other command names
##   its subject; a replay entry reading "place at cell X" with no record of
##   what was placed would not be diagnosable. It also doubles as the staleness
##   check at execution time: see execute_place_building_command()'s doc
##   comment (scripts/buildings/building_controller.gd) for why a command
##   whose building_id no longer matches the queue's current order is
##   discarded rather than placing whatever happens to be ready by then.
##
## Issued by BuildingController._try_place_ready_building() and executed by
## BuildingController.execute_place_building_command(), reached through
## CommandExecutor.execute()'s dispatch (scripts/match/command_executor.gd)
## on the tick the bus schedules it for. This command names no entity id, so
## that branch forwards straight to the building controller without
## resolving anything first -- exactly like SimBuildOrderCommand's branch,
## see its doc comment.

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
const TYPE_ID := 11

var building_id: StringName = &""
var nav_cell: Vector2i = Vector2i.ZERO
var rotation_quarter_turns: int = 0


func type_id() -> int:
	return TYPE_ID


## Payload order: building_id (see SimCommand._write_string_name()), then
## nav_cell (see SimCommand._write_cell()), then rotation_quarter_turns.
## read_payload() below must read these back in this exact order.
func write_payload(buffer: StreamPeerBuffer) -> void:
	_write_string_name(buffer, building_id)
	_write_cell(buffer, nav_cell)
	buffer.put_32(rotation_quarter_turns)


func read_payload(buffer: StreamPeerBuffer) -> bool:
	var id: Variant = _read_string_name(buffer)
	if id == null:
		return false
	var cell: Variant = _read_cell(buffer)
	if cell == null:
		return false
	if buffer.get_available_bytes() < 4:
		return false
	building_id = id
	nav_cell = cell
	rotation_quarter_turns = buffer.get_32()
	return true
