class_name UnitNavigationMap
extends RefCounted
## Runtime facade over the baked map. Static terrain stays immutable while
## buildings and other persistent obstacles live in a cheap revisioned overlay.

const MapNavigationGridScript := preload("res://scripts/world/map/map_navigation_grid.gd")

var grid: MapNavigationGrid
var revision := 0

var _blocked := PackedByteArray()
var _no_stop := PackedByteArray()
## Cell indices touched by the most recent `replace_blocked_cells` call that
## actually changed something. Lets callers reroute only the agents whose
## route passes through the change instead of every commanded agent.
var _changed_cells := PackedInt32Array()


func setup(source_grid: MapNavigationGrid) -> bool:
	grid = source_grid
	if grid == null or not grid.is_loaded():
		return false
	_blocked.resize(MapNavigationGridScript.NAV_SIZE * MapNavigationGridScript.NAV_SIZE)
	_blocked.fill(0)
	_no_stop.resize(MapNavigationGridScript.NAV_SIZE * MapNavigationGridScript.NAV_SIZE)
	_no_stop.fill(0)
	revision = 1
	return true


## `no_stop_cells` are traversable building aprons that may be crossed by any
## route, but may never be selected as an ordinary stopping destination.
func replace_blocked_cells(cells: Dictionary, new_no_stop_cells: Dictionary = {}) -> bool:
	if grid == null:
		return false
	var next := _bytes_from_cells(cells)
	var next_no_stop := _bytes_from_cells(new_no_stop_cells)
	if next == _blocked and next_no_stop == _no_stop:
		_changed_cells = PackedInt32Array()
		return false
	var changed := PackedInt32Array()
	for index in _blocked.size():
		if next[index] != _blocked[index] or next_no_stop[index] != _no_stop[index]:
			changed.append(index)
	_blocked = next
	_no_stop = next_no_stop
	_changed_cells = changed
	revision += 1
	return true


## Cell indices whose blocked/no-stop state changed on the most recent
## `replace_blocked_cells` call that returned true. Empty otherwise.
func changed_cells() -> PackedInt32Array:
	return _changed_cells


func _bytes_from_cells(cells: Dictionary) -> PackedByteArray:
	var bytes := PackedByteArray()
	bytes.resize(_blocked.size())
	for value in cells.keys():
		if value is Vector2i:
			var index := grid.cell_index(value)
			if index >= 0:
				bytes[index] = 1
	return bytes


func is_blocked(cell: Vector2i) -> bool:
	var index := grid.cell_index(cell) if grid != null else -1
	return index < 0 or _blocked[index] != 0


func is_no_stop(cell: Vector2i) -> bool:
	var index := grid.cell_index(cell) if grid != null else -1
	return index < 0 or _no_stop[index] != 0


func blocked_cells() -> PackedByteArray:
	return _blocked


func no_stop_cells() -> PackedByteArray:
	return _no_stop


func is_stoppable(cell: Vector2i, pass_mask: int, clearance_cells := 0, allowed_terrain_mask := 0) -> bool:
	if not is_passable(cell, pass_mask, clearance_cells, allowed_terrain_mask):
		return false
	var index := grid.cell_index(cell)
	return index >= 0 and _no_stop[index] == 0


## Exact body fit at a world point, for choosing a place to stand.
##
## `clearance_cells` below approximates the unit as a Chebyshev square of whole
## cells, which is the right shape for the routing grid (it is baked once and
## queried per cell) but the wrong one for a destination the player picked by
## eye: the square overshoots a diagonal or stair-stepped boundary by up to
## sqrt(2) while undershooting a straight one. This instead asks the real
## question — does the unit's body disc, centred here, clear every solid cell.
func body_fits(point: Vector3, pass_mask: int, radius: float, allowed_terrain_mask := 0) -> bool:
	if grid == null:
		return false
	if radius <= 0.0:
		return true
	var cell_size: Vector2 = grid.cell_size()
	var origin: Vector2i = grid.world_to_grid(point)
	var reach := Vector2i(
		ceili(radius / maxf(cell_size.x, 0.001)) + 1,
		ceili(radius / maxf(cell_size.y, 0.001)) + 1
	)
	# The scanned window is a square but the body is a disc, so most samples are
	# out of range. Distance is plain arithmetic while solidity costs several
	# grid lookups, so range is tested first and squared to skip the roots.
	var origin_corner: Vector3 = grid.grid_to_world(origin, false)
	var limit := radius * radius
	for y in range(-reach.y, reach.y + 1):
		var near_z := clampf(
			point.z, origin_corner.z + float(y) * cell_size.y,
			origin_corner.z + float(y + 1) * cell_size.y
		)
		var offset_z := point.z - near_z
		var span_z := offset_z * offset_z
		if span_z >= limit:
			continue
		for x in range(-reach.x, reach.x + 1):
			var near_x := clampf(
				point.x, origin_corner.x + float(x) * cell_size.x,
				origin_corner.x + float(x + 1) * cell_size.x
			)
			var offset_x := point.x - near_x
			if offset_x * offset_x + span_z >= limit:
				continue
			if _cell_obstructs(origin + Vector2i(x, y), pass_mask, allowed_terrain_mask):
				return false
	return true


## Solid for body-fit purposes. Out-of-bounds counts as solid so a body disc
## never hangs over the map edge.
func _cell_obstructs(cell: Vector2i, pass_mask: int, allowed_terrain_mask: int) -> bool:
	if grid == null or not grid.in_bounds(cell):
		return true
	if not grid.is_passable(cell, pass_mask):
		return true
	if allowed_terrain_mask != 0 and (allowed_terrain_mask & (1 << grid.terrain_at(cell))) == 0:
		return true
	return is_blocked(cell)


func is_passable(cell: Vector2i, pass_mask: int, clearance_cells := 0, allowed_terrain_mask := 0) -> bool:
	if grid == null or not grid.is_passable(cell, pass_mask):
		return false
	for y in range(-clearance_cells, clearance_cells + 1):
		for x in range(-clearance_cells, clearance_cells + 1):
			var sample := cell + Vector2i(x, y)
			if not grid.is_passable(sample, pass_mask) or is_blocked(sample):
				return false
			if allowed_terrain_mask != 0 and (allowed_terrain_mask & (1 << grid.terrain_at(sample))) == 0:
				return false
	return true


func movement_cost(cell: Vector2i) -> float:
	return grid.cost_at(cell) if grid != null else INF


func nearest_passable(origin: Vector2i, pass_mask: int, clearance_cells: int, max_radius := 24, allowed_terrain_mask := 0, stoppable_only := false) -> Vector2i:
	if _candidate_ok(origin, pass_mask, clearance_cells, allowed_terrain_mask, stoppable_only):
		return origin
	for radius in range(1, max_radius + 1):
		for x in range(-radius, radius + 1):
			for y in [-radius, radius]:
				var candidate := origin + Vector2i(x, y)
				if _candidate_ok(candidate, pass_mask, clearance_cells, allowed_terrain_mask, stoppable_only):
					return candidate
		for y in range(-radius + 1, radius):
			for x in [-radius, radius]:
				var candidate := origin + Vector2i(x, y)
				if _candidate_ok(candidate, pass_mask, clearance_cells, allowed_terrain_mask, stoppable_only):
					return candidate
	return Vector2i(-1, -1)


func _candidate_ok(cell: Vector2i, pass_mask: int, clearance_cells: int, allowed_terrain_mask: int, stoppable_only: bool) -> bool:
	if stoppable_only:
		return is_stoppable(cell, pass_mask, clearance_cells, allowed_terrain_mask)
	return is_passable(cell, pass_mask, clearance_cells, allowed_terrain_mask)
