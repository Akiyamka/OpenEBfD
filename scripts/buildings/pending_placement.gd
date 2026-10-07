class_name PendingPlacement
extends RefCounted

## Per-player deferred placement input. The command already supplies the
## player id, so it is the dictionary key rather than duplicate entry data.
class Entry extends RefCounted:
	var building_id: StringName
	var nav_cell: Vector2i
	var rotation_quarter_turns: int
	var ticks_left: int


var _by_player_id: Dictionary = {}


func begin(
		player_id: int, building_id: StringName, nav_cell: Vector2i,
		rotation_quarter_turns: int, ticks_left: int
	) -> void:
	var entry := Entry.new()
	entry.building_id = building_id
	entry.nav_cell = nav_cell
	entry.rotation_quarter_turns = rotation_quarter_turns
	entry.ticks_left = ticks_left
	_by_player_id[player_id] = entry


## `attempt` returns true once the command has reached any terminal verdict.
## The dictionary's insertion order is the command-execution priority: two
## overlapping sites that clear together are retried in that same order.
func advance_tick(attempt: Callable, expired: Callable) -> void:
	# Terminal attempts erase entries. Iterate a snapshot so a successful first
	# player cannot skip a later, overlapping retry in this same simulation tick.
	for player_id in _by_player_id.keys():
		var entry: Entry = _by_player_id[player_id]
		entry.ticks_left -= 1
		if bool(attempt.call(player_id, entry)):
			_by_player_id.erase(player_id)
			continue
		if entry.ticks_left <= 0:
			expired.call(player_id, entry)
			_by_player_id.erase(player_id)


func reserved_nav_cells(cells_for_entry: Callable) -> Array[Vector2i]:
	var cells: Array[Vector2i] = []
	for player_id in _by_player_id:
		var entry: Entry = _by_player_id[player_id]
		for cell in cells_for_entry.call(player_id, entry):
			if not cells.has(cell):
				cells.append(cell)
	return cells


func has_entry(player_id: int) -> bool:
	return _by_player_id.has(player_id)
