class_name CombatLineGrid
extends RefCounted

## AO1's post-movement broad phase.  This intentionally knows only stable ids,
## XZ positions and radii: nodes, RIDs and allegiance stay outside sim and are
## resolved by CombatLineOfFire after this helper returns local ids.

const CELL_WIDTH := 4.0

var _buckets: Dictionary = {}
var _query_ids := PackedInt32Array()
var _bucket_writes := 0
var _query_cell_probes := 0
var _step_cap_hits := 0


func clear() -> void:
	_buckets.clear()
	_bucket_writes = 0
	_query_cell_probes = 0
	_step_cap_hits = 0


func insert(id: int, position: Vector3, radius: float) -> void:
	var min_x := floori((position.x - radius) / CELL_WIDTH)
	var max_x := floori((position.x + radius) / CELL_WIDTH)
	var min_z := floori((position.z - radius) / CELL_WIDTH)
	var max_z := floori((position.z + radius) / CELL_WIDTH)
	for cell_x in range(min_x, max_x + 1):
		for cell_z in range(min_z, max_z + 1):
			var key := Vector2i(cell_x, cell_z)
			var ids := PackedInt32Array() if not _buckets.has(key) else _buckets[key] as PackedInt32Array
			ids.append(id)
			_buckets[key] = ids
			_bucket_writes += 1


## Returns stable ids in ascending order.  The grid inserts every cell touched
## by a candidate's padded horizontal footprint, while this walks the raw shot
## segment; these dual coverages catch every possible circle contact.
func query_segment(from: Vector3, to: Vector3) -> PackedInt32Array:
	_query_ids.clear()
	var start_x := floori(from.x / CELL_WIDTH)
	var start_z := floori(from.z / CELL_WIDTH)
	var end_x := floori(to.x / CELL_WIDTH)
	var end_z := floori(to.z / CELL_WIDTH)
	_visit_point_cells(from)
	if start_x != end_x or start_z != end_z:
		_walk_supercover(from, to, start_x, start_z, end_x, end_z)
	_visit_point_cells(to)
	if _query_ids.size() < 2:
		return _query_ids
	_query_ids.sort()
	var unique_size := 1
	for read_index in range(1, _query_ids.size()):
		if _query_ids[read_index] == _query_ids[unique_size - 1]:
			continue
		_query_ids[unique_size] = _query_ids[read_index]
		unique_size += 1
	_query_ids.resize(unique_size)
	return _query_ids


func bucket_writes() -> int:
	return _bucket_writes


func query_cell_probes() -> int:
	return _query_cell_probes


func step_cap_hits() -> int:
	return _step_cap_hits


func _walk_supercover(
		from: Vector3, to: Vector3, cell_x: int, cell_z: int, end_x: int, end_z: int
	) -> void:
	var delta_x := to.x - from.x
	var delta_z := to.z - from.z
	var step_x := 1 if delta_x > 0.0 else -1
	var step_z := 1 if delta_z > 0.0 else -1
	var t_delta_x := absf(CELL_WIDTH / delta_x) if delta_x != 0.0 else INF
	var t_delta_z := absf(CELL_WIDTH / delta_z) if delta_z != 0.0 else INF
	var boundary_x := float(cell_x + (1 if step_x > 0 else 0)) * CELL_WIDTH
	var boundary_z := float(cell_z + (1 if step_z > 0 else 0)) * CELL_WIDTH
	var t_max_x := (boundary_x - from.x) / delta_x if delta_x != 0.0 else INF
	var t_max_z := (boundary_z - from.z) / delta_z if delta_z != 0.0 else INF
	# Every iteration reduces the remaining Manhattan cell distance. Even a
	# malformed near-corner tie therefore has a finite, observable failure.
	var step_limit := absi(end_x - cell_x) + absi(end_z - cell_z) + 1
	for _step in step_limit:
		if cell_x == end_x and cell_z == end_z:
			return
		var can_x := cell_x != end_x
		var can_z := cell_z != end_z
		if can_x and can_z and is_finite(t_max_x) and is_finite(t_max_z) \
		and is_equal_approx(t_max_x, t_max_z):
			# A corner touches both side cells as well as the diagonal cell.
			_visit(cell_x + step_x, cell_z)
			_visit(cell_x, cell_z + step_z)
			cell_x += step_x
			cell_z += step_z
			t_max_x += t_delta_x
			t_max_z += t_delta_z
		elif can_x and (not can_z or t_max_x < t_max_z):
			cell_x += step_x
			t_max_x += t_delta_x
		else:
			cell_z += step_z
			t_max_z += t_delta_z
		_visit_walk_cell(cell_x, cell_z, from, to)
	_step_cap_hits += 1
	_visit(end_x, end_z)


func _visit_walk_cell(cell_x: int, cell_z: int, from: Vector3, to: Vector3) -> void:
	_visit(cell_x, cell_z)
	# A segment lying exactly on a grid line touches both adjacent strips.
	var on_x_edge := from.x == to.x and from.x == float(cell_x) * CELL_WIDTH
	var on_z_edge := from.z == to.z and from.z == float(cell_z) * CELL_WIDTH
	if on_x_edge:
		_visit(cell_x - 1, cell_z)
	if on_z_edge:
		_visit(cell_x, cell_z - 1)
	if on_x_edge and on_z_edge:
		_visit(cell_x - 1, cell_z - 1)


func _visit_point_cells(point: Vector3) -> void:
	var cell_x := floori(point.x / CELL_WIDTH)
	var cell_z := floori(point.z / CELL_WIDTH)
	_visit(cell_x, cell_z)
	var on_x_edge := point.x == float(cell_x) * CELL_WIDTH
	var on_z_edge := point.z == float(cell_z) * CELL_WIDTH
	if on_x_edge:
		_visit(cell_x - 1, cell_z)
	if on_z_edge:
		_visit(cell_x, cell_z - 1)
	if on_x_edge and on_z_edge:
		_visit(cell_x - 1, cell_z - 1)


func _visit(cell_x: int, cell_z: int) -> void:
	_query_cell_probes += 1
	var key := Vector2i(cell_x, cell_z)
	if not _buckets.has(key):
		return
	var ids: PackedInt32Array = _buckets[key]
	_query_ids.append_array(ids)
