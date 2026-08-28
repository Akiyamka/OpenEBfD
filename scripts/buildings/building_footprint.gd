class_name BuildingFootprint
extends RefCounted

const SpatialOrientationScript := preload("res://scripts/world/spatial_orientation.gd")
const EntityQueryScript := preload("res://scripts/world/entity_query.gd")
const OccupyGridScript := preload("res://scripts/buildings/occupy_grid.gd")
const AXIS_ALIGNMENT_DOT := 0.9999
const EDGE_EPSILON := 0.00001


## Returns navigation cells keyed by Vector2i with the source occupy marker as
## the value. Imported building rows advance toward the building's exit (+Z),
## so rotating the building rotates the footprint around its world position.
static func nav_cells_by_marker(
		building: Node3D, occupy_rows: Array, navigation_grid, cells_per_occupy_cell: int
	) -> Dictionary:
	var result := {}
	if building == null or navigation_grid == null or occupy_rows.is_empty() or cells_per_occupy_cell <= 0:
		return result

	var width := _row_width(occupy_rows)
	if width <= 0:
		return result
	var right := SpatialOrientationScript.world_right(building)
	var exit_direction := _building_exit_direction(building)
	if right.is_zero_approx() or exit_direction.is_zero_approx():
		return result

	# Preserve the exact persisted anchor for the normal, unrotated placement
	# path. Once a building rotates, its world transform becomes authoritative.
	var saved_anchor = building.get_meta(&"placement_anchor_cell") if building.has_meta(&"placement_anchor_cell") else null
	if saved_anchor is Vector2i and _uses_grid_axes(right, exit_direction):
		_fill_axis_aligned(result, saved_anchor, occupy_rows, cells_per_occupy_cell)
		return result

	var origin: Vector3 = navigation_grid.grid_to_world(Vector2i.ZERO, false)
	var x_step: Vector3 = navigation_grid.grid_to_world(Vector2i(1, 0), false) - origin
	var z_step: Vector3 = navigation_grid.grid_to_world(Vector2i(0, 1), false) - origin
	var cell_width := Vector2(x_step.x, x_step.z).length()
	var cell_depth := Vector2(z_step.x, z_step.z).length()
	if cell_width <= EDGE_EPSILON or cell_depth <= EDGE_EPSILON:
		return result

	var nav_width := width * cells_per_occupy_cell
	var nav_depth := occupy_rows.size() * cells_per_occupy_cell
	var half_width_world := float(nav_width) * cell_width * 0.5
	var half_depth_world := float(nav_depth) * cell_depth * 0.5
	var center: Vector3 = building.simulation_position() if building.is_inside_tree() else building.position
	var corners := [
		center - right * half_width_world - exit_direction * half_depth_world,
		center + right * half_width_world - exit_direction * half_depth_world,
		center - right * half_width_world + exit_direction * half_depth_world,
		center + right * half_width_world + exit_direction * half_depth_world,
	]
	var minimum: Vector2i = navigation_grid.world_to_grid(corners[0])
	var maximum: Vector2i = minimum
	for corner in corners:
		var cell: Vector2i = navigation_grid.world_to_grid(corner)
		minimum = Vector2i(mini(minimum.x, cell.x), mini(minimum.y, cell.y))
		maximum = Vector2i(maxi(maximum.x, cell.x), maxi(maximum.y, cell.y))
	minimum -= Vector2i.ONE
	maximum += Vector2i.ONE

	for grid_y in range(minimum.y, maximum.y + 1):
		for grid_x in range(minimum.x, maximum.x + 1):
			var grid_cell := Vector2i(grid_x, grid_y)
			var world_center: Vector3 = navigation_grid.grid_to_world(grid_cell, true)
			var relative := world_center - center
			var local_nav_x := relative.dot(right) / cell_width + float(nav_width) * 0.5
			var local_nav_z := relative.dot(exit_direction) / cell_depth + float(nav_depth) * 0.5
			if (
				local_nav_x < -EDGE_EPSILON
				or local_nav_z < -EDGE_EPSILON
				or local_nav_x >= float(nav_width) - EDGE_EPSILON
				or local_nav_z >= float(nav_depth) - EDGE_EPSILON
			):
				continue
			var column := floori(maxf(local_nav_x, 0.0) / float(cells_per_occupy_cell))
			var row_index := floori(maxf(local_nav_z, 0.0) / float(cells_per_occupy_cell))
			var marker := _marker_at(occupy_rows, column, row_index)
			if not _is_empty_marker(marker):
				result[grid_cell] = marker
	return result


static func _fill_axis_aligned(
		result: Dictionary, anchor: Vector2i, occupy_rows: Array, cells_per_occupy_cell: int
	) -> void:
	for row_index in occupy_rows.size():
		var row := String(occupy_rows[row_index])
		for column in row.length():
			var marker := row.substr(column, 1)
			if _is_empty_marker(marker):
				continue
			var cell_origin := anchor + Vector2i(column, row_index) * cells_per_occupy_cell
			for y in cells_per_occupy_cell:
				for x in cells_per_occupy_cell:
					result[cell_origin + Vector2i(x, y)] = marker


static func _building_exit_direction(building: Node3D) -> Vector3:
	return EntityQueryScript.exit_direction(building)


static func _uses_grid_axes(right: Vector3, exit_direction: Vector3) -> bool:
	return right.dot(Vector3.RIGHT) > AXIS_ALIGNMENT_DOT and exit_direction.dot(Vector3.BACK) > AXIS_ALIGNMENT_DOT


static func _row_width(occupy_rows: Array) -> int:
	return OccupyGridScript.width(occupy_rows)


static func _marker_at(occupy_rows: Array, column: int, row_index: int) -> String:
	if row_index < 0 or row_index >= occupy_rows.size():
		return ""
	var row := String(occupy_rows[row_index])
	return row.substr(column, 1) if column >= 0 and column < row.length() else ""


static func _is_empty_marker(marker: String) -> bool:
	return OccupyGridScript.is_empty_marker(marker)
