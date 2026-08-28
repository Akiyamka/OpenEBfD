class_name SimWallLineCommand
extends SimCommand

## "Wall line": the second click of the wall-line picker, the one that used to
## fix the line in place and start ordering its first segment the instant the
## mouse went down. Named by the two clicked cells plus the stable building_id
## the player was drawing with -- not by Node, for the same reason
## SimPlaceBuildingCommand's doc comment gives (scripts/sim/commands/
## place_building_command.gd): sim-zone code may never hold a Node reference,
## see docs/architecture/network-multiplayer.md, decision 3, and the
## sim-no-node-api rule in tools/architecture_rules.toml.
##
## All three fields are player input, never a verdict. In particular, this
## command deliberately does NOT carry the buildable-cell set
## WallLineSession.click() used to read off the preview
## (BuildingPlacement.available_preview_anchor_cells()) at the moment of the
## second click. A wall line is not built in one shot -- ProductionSystem
## orders one segment at a time, over many seconds, as each previous segment
## finishes -- so "which cells were buildable when the
## player aimed" is stale by the time most of those segments are actually
## ordered, let alone by the time this command reaches its execution tick on
## every client. The preview is drawn for the player's eyes only and is
## allowed to be wrong; ProductionSystem (scripts/production/
## production_system.gd) recomputes the real buildable set against the map as
## it stands at execution time, through BuildingPlacement -- the one shared
## implementation of every "can this go here" check -- exactly the reasoning
## SimPlaceBuildingCommand's doc comment gives for keeping verdicts out of the
## struct (see SimMoveCommand's doc comment for the identical argument,
## stated first).
##
## - start_cell/end_cell are the two clicks, already resolved from screen
##   space to grid cells by the local raycast at issue time
##   (BuildingPlacement.hover_cell_from_pointer()) -- the same treatment
##   SimPlaceBuildingCommand.nav_cell gets from its own raycast.
## - building_id says which wall the player was drawing with. Every other
##   command names its subject; a replay entry reading "line from X to Y"
##   with no record of what was being built would not be diagnosable.
##
## Issued by BuildingController._finish_wall_selection() (the second click)
## and executed by BuildingController.execute_wall_line_command(), reached
## through CommandExecutor.execute()'s dispatch
## (scripts/match/command_executor.gd) on the tick the bus schedules it for.
## This command names no entity id, so that branch forwards straight to the
## building controller without resolving anything first -- exactly like
## SimBuildOrderCommand's and SimPlaceBuildingCommand's branches, see their
## own doc comments.

## Dispatch id for CommandExecutor.execute()
## (scripts/match/command_executor.gd) and SimCommandCodec
## (scripts/sim/command_codec.gd). Which ids are already claimed is recorded
## in exactly one place -- SimCommandCodec._COMMAND_SCRIPTS -- and
## tests/sim/command_codec_run.gd fails if a command type is missing from
## that table, so the next command type reads its id off that list.
const TYPE_ID := 12

var building_id: StringName = &""
var start_cell: Vector2i = Vector2i.ZERO
var end_cell: Vector2i = Vector2i.ZERO


func type_id() -> int:
	return TYPE_ID


## Payload order: building_id (see SimCommand._write_string_name()), then
## start_cell, then end_cell (see SimCommand._write_cell()). read_payload()
## below must read these back in this exact order.
func write_payload(buffer: StreamPeerBuffer) -> void:
	_write_string_name(buffer, building_id)
	_write_cell(buffer, start_cell)
	_write_cell(buffer, end_cell)


func read_payload(buffer: StreamPeerBuffer) -> bool:
	var id: Variant = _read_string_name(buffer)
	if id == null:
		return false
	var from_cell: Variant = _read_cell(buffer)
	if from_cell == null:
		return false
	var to_cell: Variant = _read_cell(buffer)
	if to_cell == null:
		return false
	building_id = id
	start_cell = from_cell
	end_cell = to_cell
	return true
