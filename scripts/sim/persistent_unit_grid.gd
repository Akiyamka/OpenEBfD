extends RefCounted

const CombatLineGridScript := preload("res://scripts/sim/combat_line_grid.gd")
const CELL_WIDTH := CombatLineGridScript.CELL_WIDTH

var _buckets: Dictionary = {}
var _footprints: Dictionary = {}
var _occupied_rows: Dictionary = {}
var _bucket_writes := 0
var _query_cell_probes := 0


func clear() -> void:
	_buckets.clear()
	_footprints.clear()
	_occupied_rows.clear()
	_bucket_writes = 0
	_query_cell_probes = 0


func has_id(id: int) -> bool:
	return _footprints.has(id)


func bucket_writes() -> int:
	return _bucket_writes


func query_cell_probes() -> int:
	return _query_cell_probes


func upsert(id: int, position: Vector3, radius: float) -> void:
	var footprint := Rect2i(
		floori((position.x - radius) / CELL_WIDTH),
		floori((position.z - radius) / CELL_WIDTH),
		floori((position.x + radius) / CELL_WIDTH) - floori((position.x - radius) / CELL_WIDTH) + 1,
		floori((position.z + radius) / CELL_WIDTH) - floori((position.z - radius) / CELL_WIDTH) + 1
	)
	if _footprints.has(id) and _footprints[id] == footprint:
		return
	remove(id)
	_footprints[id] = footprint
	for x in range(footprint.position.x, footprint.end.x):
		for z in range(footprint.position.y, footprint.end.y):
			var key := Vector2i(x, z)
			if not _buckets.has(key):
				_occupied_rows[z] = int(_occupied_rows.get(z, 0)) + 1
			var bucket: Dictionary = _buckets.get(key, {})
			bucket[id] = true
			_buckets[key] = bucket
			_bucket_writes += 1


func remove(id: int) -> void:
	if not _footprints.has(id):
		return
	var footprint: Rect2i = _footprints[id]
	for x in range(footprint.position.x, footprint.end.x):
		for z in range(footprint.position.y, footprint.end.y):
			var key := Vector2i(x, z)
			var bucket: Dictionary = _buckets[key]
			bucket.erase(id)
			if bucket.is_empty():
				_buckets.erase(key)
				var remaining := int(_occupied_rows[z]) - 1
				if remaining == 0:
					_occupied_rows.erase(z)
				else:
					_occupied_rows[z] = remaining
			else:
				_buckets[key] = bucket
			_bucket_writes += 1
	_footprints.erase(id)


func rectangle_candidates(min_xz: Vector2, max_xz: Vector2) -> PackedInt32Array:
	if not min_xz.is_finite() or not max_xz.is_finite() or min_xz.x > max_xz.x or min_xz.y > max_xz.y:
		push_error("PersistentUnitGrid: invalid rectangle")
		return PackedInt32Array()
	var min_x := floori(min_xz.x / CELL_WIDTH)
	var min_z := floori(min_xz.y / CELL_WIDTH)
	if min_xz.x == float(min_x) * CELL_WIDTH:
		min_x -= 1
	if min_xz.y == float(min_z) * CELL_WIDTH:
		min_z -= 1
	var found: Dictionary = {}
	for x in range(min_x, floori(max_xz.x / CELL_WIDTH) + 1):
		for z in range(min_z, floori(max_xz.y / CELL_WIDTH) + 1):
			_collect(x, z, found)
	return _sorted(found)


func padded_segment_candidates(from: Vector3, to: Vector3, padding: float) -> PackedInt32Array:
	if not from.is_finite() or not to.is_finite() or not is_finite(padding) or padding < 0.0:
		push_error("PersistentUnitGrid: invalid segment")
		return PackedInt32Array()
	var halo := ceili(padding / CELL_WIDTH)
	var first_row := floori(minf(from.z, to.z) / CELL_WIDTH) - 1
	var last_row := floori(maxf(from.z, to.z) / CELL_WIDTH)
	var dz := to.z - from.z
	var spans: Array[Vector2i] = []
	for base_row in range(first_row, last_row + 1):
		var low_t := 0.0
		var high_t := 1.0
		if dz == 0.0:
			if from.z < float(base_row) * CELL_WIDTH or from.z > float(base_row + 1) * CELL_WIDTH:
				spans.append(Vector2i(2147483647, -2147483647))
				continue
		else:
			var t_a := (float(base_row) * CELL_WIDTH - from.z) / dz
			var t_b := (float(base_row + 1) * CELL_WIDTH - from.z) / dz
			low_t = maxf(0.0, minf(t_a, t_b))
			high_t = minf(1.0, maxf(t_a, t_b))
			if low_t > high_t:
				spans.append(Vector2i(2147483647, -2147483647))
				continue
		var x_a := from.x + (to.x - from.x) * low_t
		var x_b := from.x + (to.x - from.x) * high_t
		var left := floori(minf(x_a, x_b) / CELL_WIDTH)
		if minf(x_a, x_b) == float(left) * CELL_WIDTH:
			left -= 1
		spans.append(Vector2i(left, floori(maxf(x_a, x_b) / CELL_WIDTH)))
	var found: Dictionary = {}
	for row in range(first_row - halo, last_row + halo + 1):
		var min_x := 2147483647
		var max_x := -2147483647
		for base_row in range(maxi(first_row, row - halo), mini(last_row, row + halo) + 1):
			var span: Vector2i = spans[base_row - first_row]
			min_x = mini(min_x, span.x)
			max_x = maxi(max_x, span.y)
		if min_x <= max_x:
			if not _occupied_rows.has(row):
				_query_cell_probes += max_x - min_x + 2 * halo + 1
				continue
			for cx in range(min_x - halo, max_x + halo + 1):
				_collect(cx, row, found)
	return _sorted(found)


func _collect(x: int, z: int, found: Dictionary) -> void:
	_query_cell_probes += 1
	var key := Vector2i(x, z)
	if not _buckets.has(key):
		return
	var bucket: Dictionary = _buckets[key]
	for id in bucket:
		found[id] = true


func _sorted(found: Dictionary) -> PackedInt32Array:
	var ids := PackedInt32Array()
	for id in found:
		ids.append(id)
	ids.sort()
	return ids
