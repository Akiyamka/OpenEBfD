class_name WallLineSession
extends RefCounted

const BuildingPlacementScript := preload("res://scripts/buildings/building_placement.gd")
const WallLineScript := preload("res://scripts/buildings/wall_line.gd")

var _marker_parent: Node3D
var _placement
var _marker_scene: PackedScene
var _start_cell = null
var _building_id: StringName = &""
var _markers: Dictionary = {}


func configure(marker_parent: Node3D, placement, wall_marker_scene: PackedScene) -> void:
	_marker_parent = marker_parent
	_placement = placement
	_marker_scene = wall_marker_scene


func begin(order_building_id: StringName, display_name: String, occupy_rows: Array[String]) -> bool:
	_start_cell = null
	_building_id = order_building_id
	return _placement.begin(order_building_id, display_name, occupy_rows, true)


func end() -> void:
	_start_cell = null
	_building_id = &""


## The second click names only the two cells and wall id. ProductionSystem
## recomputes the real buildable set when the scheduled command executes.
func click(screen_position: Vector2, status: Callable, start_chain_callback: Callable) -> void:
	var cell = _placement.hover_cell_from_pointer(screen_position)
	if cell == null:
		status.call("Wall placement needs terrain")
		return
	if _start_cell == null:
		_start_cell = cell
		status.call("Wall start set; click the line end")
		return
	var start: Vector2i = _start_cell
	start_chain_callback.call(start, cell, _building_id)


func process_preview(screen_position: Vector2) -> void:
	if not _placement.is_active():
		return
	var hover_cell = _placement.hover_cell_from_pointer(screen_position)
	if hover_cell == null:
		var no_cells: Array[Vector2i] = []
		_placement.preview_at_hover_cells(no_cells)
		return
	preview_to(hover_cell)


func preview_to(hover_cell: Vector2i) -> void:
	var preview_cells: Array[Vector2i] = [hover_cell]
	if _start_cell != null:
		preview_cells = nav_cells_between(_start_cell, hover_cell)
	_placement.preview_at_hover_cells(preview_cells)


func nav_cells_between(from_nav_cell: Vector2i, to_nav_cell: Vector2i) -> Array[Vector2i]:
	var span := BuildingPlacementScript.NAV_CELLS_PER_OCCUPY_CELL
	var from_occupy := Vector2i(
		int(floor(float(from_nav_cell.x) / float(span))),
		int(floor(float(from_nav_cell.y) / float(span)))
	)
	var to_occupy := Vector2i(
		int(floor(float(to_nav_cell.x) / float(span))),
		int(floor(float(to_nav_cell.y) / float(span)))
	)
	var occupy_cells := WallLineScript.occupy_cells_between(from_occupy, to_occupy)
	var nav_cells: Array[Vector2i] = []
	for occupy_cell in occupy_cells:
		nav_cells.append(occupy_cell * span)
	return nav_cells


func lock_markers(anchor_cells: Array[Vector2i]) -> void:
	clear_markers()
	if _marker_scene == null:
		return
	for anchor_cell in anchor_cells:
		var marker := _marker_scene.instantiate() as Node3D
		if marker == null:
			continue
		marker.name = "WallMarker_%d_%d" % [anchor_cell.x, anchor_cell.y]
		_marker_parent.add_child(marker)
		marker.global_position = _placement.wall_marker_world_position(anchor_cell)
		_markers[anchor_cell] = marker


func remove_marker(anchor_cell: Vector2i) -> void:
	var marker := _markers.get(anchor_cell) as Node3D
	_markers.erase(anchor_cell)
	if marker == null:
		return
	if marker.get_parent() == _marker_parent:
		_marker_parent.remove_child(marker)
	marker.queue_free()


func clear_markers() -> void:
	for anchor_cell in _markers.keys():
		remove_marker(anchor_cell)


func start_cell():
	return _start_cell


func set_start_cell(value) -> void:
	_start_cell = value


func current_building_id() -> StringName:
	return _building_id


func set_building_id(value: StringName) -> void:
	_building_id = value


func markers() -> Dictionary:
	return _markers


func set_marker_scene(value: PackedScene) -> void:
	_marker_scene = value
