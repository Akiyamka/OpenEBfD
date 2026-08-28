class_name WallChain
extends RefCounted

## Tracks a wall's line-of-cells order: one BuildingQueue order per buildable
## cell. Blocked cells are advanced past without an order; otherwise the next
## cell is queued once the previous one finishes by ProductionSystem.
## Cancelling the current cell's order simply drops this chain, which stops
## the auto-continuation (docs/mechanics/production.md section 2 "walls").

var building_id: StringName
var display_name := ""
var cost := 0
var build_time_ticks := 0
var cells: Array[Vector2i] = []
var owner_player_id

var _index := 0


func _init(
		chain_building_id: StringName,
		chain_display_name: String,
		chain_cost: int,
		chain_build_time_ticks: int,
		chain_cells: Array[Vector2i],
		chain_owner_player_id = null
	) -> void:
	building_id = chain_building_id
	display_name = chain_display_name
	cost = chain_cost
	build_time_ticks = chain_build_time_ticks
	cells = chain_cells
	owner_player_id = chain_owner_player_id


func is_empty() -> bool:
	return cells.is_empty()


func current_cell() -> Vector2i:
	return cells[_index]


func segment_index() -> int:
	return _index + 1


func segment_count() -> int:
	return cells.size()


## Moves to the next cell; returns false once the chain has placed its last cell.
func advance() -> bool:
	_index += 1
	return _index < cells.size()
