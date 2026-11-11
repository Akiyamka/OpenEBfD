class_name UnitAuthoredCollision
extends RefCounted

## Everything a unit derives from the collision volumes baked into its converted
## model: the physics shapes added to the body, the horizontal extents the
## navigation system asks for, and the selection bounds combat aims at.
##
## Owns no model nodes. Navigation and selection still walk `visual_root`
## fresh, but the combat firing-line hull is captured when the body shape is
## installed. A later visual interpolation/animation pose must not change a
## simulation verdict.

const AuthoredModelScript := preload("res://scripts/world/authored_model.gd")

## The converted models' unnamed collision object. Units that have one use it;
## the `slct` selection volumes are the fallback for models that do not.
const COLLISION_OBJECT_NAME := "#~~0"
const SOURCE_PREFERENCE := [
	{"name": COLLISION_OBJECT_NAME, "prefix": false},
	{"name": "slct", "prefix": true},
]

var _unit: CharacterBody3D
var _combat_line_hulls: Array[Dictionary] = []
var _combat_line_bounds := {}
var _hull_copy_count := 0
var _contact_probe_count := 0


func configure(unit: CharacterBody3D) -> void:
	_unit = unit


func dispose() -> void:
	_unit = null
	_combat_line_hulls.clear()
	_combat_line_bounds.clear()


## Adds one CollisionShape3D per authored collision volume directly to the body.
## Called once from Unit._ready(); the unit keeps collision_mask at 0, so these
## shapes only serve mouse-picking rays and combat queries, never terrain
## contact (see the comment at the call site).
func add_body_shapes() -> void:
	if _unit == null:
		return
	_combat_line_hulls.clear()
	_combat_line_bounds.clear()
	var radius := 0.0
	var min_y := INF
	var max_y := -INF
	for source in sources():
		var shape := AuthoredModelScript.collision_shape(source)
		if shape == null:
			push_warning("Unit: collision mesh %s has no usable convex shape" % source.get_path())
			continue

		var collision := CollisionShape3D.new()
		collision.name = "AuthoredCollision"
		collision.shape = shape
		_unit.add_child(collision)
		# The source mesh is nested beneath VisualRoot and model-space nodes;
		# copying its global transform preserves its authored position and scale.
		collision.global_transform = source.global_transform
		var hull := _convex_hull_in_unit_space(shape, collision.transform)
		if not hull.is_empty():
			_combat_line_hulls.append(hull)
			for point: Vector3 in hull["points"]:
				radius = maxf(radius, Vector2(point.x, point.z).length())
				min_y = minf(min_y, point.y)
				max_y = maxf(max_y, point.y)
		else:
			push_warning("Unit: installed collision shape %s yielded no convex firing-line hull" % source.get_path())
	if not _combat_line_hulls.is_empty():
		# Packed float32 storage must never shrink the authored envelope.
		_combat_line_bounds = {"radius": radius + 0.01, "min_y": min_y - 0.01, "max_y": max_y + 0.01}


## Convex hulls used by CombatLineOfFire. These are built from the same full
## local transform as the CollisionShape3D above, including authored scale.
## They deliberately survive replace_visual_scene(): that method replaces a
## visual, not the CharacterBody3D shapes which physics and combat installed.
func combat_line_hulls() -> Array[Dictionary]:
	_hull_copy_count += 1
	return _combat_line_hulls.duplicate(true)


func hull_copy_count() -> int:
	return _hull_copy_count


func contact_probe_count() -> int:
	return _contact_probe_count


## Returns the first direct entry and exact distance from a capsule core to
## the installed convex triangles. All coordinates are transformed using the
## root yaw and the tick-owned origin supplied by the caller.
func projectile_contact(from: Vector3, to: Vector3, position: Vector3, radius: float,
		basis: Variant = null, carried := false) -> Dictionary:
	if _unit == null or _combat_line_hulls.is_empty():
		return {}
	_contact_probe_count += 1
	var transform := Transform3D(_unit.global_basis if basis == null else basis, position)
	var inverse := transform.affine_inverse()
	var local_from := inverse * from
	var local_to := inverse * to
	var segment := local_to - local_from
	var length := segment.length()
	if length <= 0.0:
		return {}
	if radius <= 0.0:
		var nearest := INF
		for hull: Dictionary in _combat_line_hulls:
			var planes: Array = hull["planes"]
			if carried and _separated_by_plane(local_from, local_to, planes, 0.0):
				continue
			if _inside_convex(local_from, planes):
				nearest = 0.0
				break
			var entry: Variant = Geometry3D.segment_intersects_convex(local_from, local_to, planes)
			if entry is PackedVector3Array and not (entry as PackedVector3Array).is_empty():
				nearest = minf(nearest, from.distance_to(transform * (entry as PackedVector3Array)[0]))
		if nearest < INF:
			return {"hit": true, "position": from + (to - from).normalized() * nearest, "entry": nearest}
		return {}
	var effective_radius := minf(radius, length * 0.5)
	var axis := segment / length
	var core_from := local_from + axis * effective_radius
	var core_to := local_to - axis * effective_radius
	var segment_min := core_from.min(core_to)
	var segment_max := core_from.max(core_to)
	var radius_squared := effective_radius * effective_radius
	for hull: Dictionary in _combat_line_hulls:
		var planes: Array = hull["planes"]
		if carried and _separated_by_plane(core_from, core_to, planes, effective_radius):
			continue
		if _inside_convex(core_from, planes) or _inside_convex(core_to, planes):
			return {"hit": true, "distance_squared": 0.0}
		var crossing: Variant = Geometry3D.segment_intersects_convex(core_from, core_to, planes)
		if crossing is PackedVector3Array and not (crossing as PackedVector3Array).is_empty():
			return {"hit": true, "distance_squared": 0.0}
		var limit: float = hull["bounding_radius"] + effective_radius
		if _point_segment_distance_squared(Vector3.ZERO, core_from, core_to) > limit * limit:
			continue
		if _box_gap_squared(segment_min, segment_max, hull["min"], hull["max"]) > radius_squared:
			continue
		var best_squared := INF
		var faces: Array = hull["faces"]
		var face_bounds: Array = hull["face_bounds"]
		for face_index in faces.size():
			var bounds: AABB = face_bounds[face_index]
			if _box_gap_squared(segment_min, segment_max, bounds.position, bounds.end) > radius_squared:
				continue
			var face: PackedVector3Array = faces[face_index]
			best_squared = minf(best_squared, _segment_triangle_distance_squared(core_from, core_to, face[0], face[1], face[2]))
			if best_squared <= radius_squared + 0.000001:
				return {"hit": true, "distance_squared": best_squared}
	return {}


func _separated_by_plane(a: Vector3, b: Vector3, planes: Array, radius: float) -> bool:
	for plane: Plane in planes:
		if plane.distance_to(a) > radius + 0.002 and plane.distance_to(b) > radius + 0.002:
			return true
	return false


func _segment_triangle_distance_squared(a: Vector3, b: Vector3, p: Vector3, q: Vector3, r: Vector3) -> float:
	var normal := (q - p).cross(r - p)
	var denominator := normal.dot(b - a)
	if absf(denominator) > 0.0000001:
		var fraction := normal.dot(p - a) / denominator
		if fraction >= 0.0 and fraction <= 1.0:
			var point := a.lerp(b, fraction)
			if _point_in_triangle(point, p, q, r, normal):
				return 0.0
	var best := minf(_point_triangle_distance_squared(a, p, q, r), _point_triangle_distance_squared(b, p, q, r))
	best = minf(best, _segment_segment_distance_squared(a, b, p, q))
	best = minf(best, _segment_segment_distance_squared(a, b, q, r))
	best = minf(best, _segment_segment_distance_squared(a, b, r, p))
	return best


func _point_in_triangle(point: Vector3, p: Vector3, q: Vector3, r: Vector3, normal: Vector3) -> bool:
	return normal.dot((q - p).cross(point - p)) >= -0.000001 \
		and normal.dot((r - q).cross(point - q)) >= -0.000001 \
		and normal.dot((p - r).cross(point - r)) >= -0.000001


func _point_triangle_distance_squared(point: Vector3, p: Vector3, q: Vector3, r: Vector3) -> float:
	var ab := q - p
	var ac := r - p
	var ap := point - p
	var d1 := ab.dot(ap)
	var d2 := ac.dot(ap)
	if d1 <= 0.0 and d2 <= 0.0:
		return ap.length_squared()
	var bp := point - q
	var d3 := ab.dot(bp)
	var d4 := ac.dot(bp)
	if d3 >= 0.0 and d4 <= d3:
		return bp.length_squared()
	var vc := d1 * d4 - d3 * d2
	if vc <= 0.0 and d1 >= 0.0 and d3 <= 0.0:
		return (point - p.lerp(q, d1 / (d1 - d3))).length_squared()
	var cp := point - r
	var d5 := ab.dot(cp)
	var d6 := ac.dot(cp)
	if d6 >= 0.0 and d5 <= d6:
		return cp.length_squared()
	var vb := d5 * d2 - d1 * d6
	if vb <= 0.0 and d2 >= 0.0 and d6 <= 0.0:
		return (point - p.lerp(r, d2 / (d2 - d6))).length_squared()
	var va := d3 * d6 - d5 * d4
	if va <= 0.0 and (d4 - d3) >= 0.0 and (d5 - d6) >= 0.0:
		return (point - q.lerp(r, (d4 - d3) / ((d4 - d3) + (d5 - d6)))).length_squared()
	var projection := point - (ab.cross(ac)).normalized() * (ab.cross(ac)).normalized().dot(ap)
	return point.distance_squared_to(projection)


func _segment_segment_distance_squared(p: Vector3, q: Vector3, a: Vector3, b: Vector3) -> float:
	var u := q - p
	var v := b - a
	var w := p - a
	var aa := u.dot(u)
	var bb := u.dot(v)
	var cc := v.dot(v)
	var dd := u.dot(w)
	var ee := v.dot(w)
	var denominator := aa * cc - bb * bb
	var best := minf(_point_segment_distance_squared(p, a, b), _point_segment_distance_squared(q, a, b))
	best = minf(best, _point_segment_distance_squared(a, p, q))
	best = minf(best, _point_segment_distance_squared(b, p, q))
	if denominator > 0.0000001:
		var s := (bb * ee - cc * dd) / denominator
		var t := (aa * ee - bb * dd) / denominator
		if s >= 0.0 and s <= 1.0 and t >= 0.0 and t <= 1.0:
			best = minf(best, (w + u * s - v * t).length_squared())
	return best


func _point_segment_distance_squared(point: Vector3, a: Vector3, b: Vector3) -> float:
	var edge := b - a
	var length_squared := edge.length_squared()
	if length_squared <= 0.0000001:
		return point.distance_squared_to(a)
	return point.distance_squared_to(a + edge * clampf((point - a).dot(edge) / length_squared, 0.0, 1.0))


func _box_gap_squared(a_min: Vector3, a_max: Vector3, b_min: Vector3, b_max: Vector3) -> float:
	var dx := maxf(maxf(b_min.x - a_max.x, a_min.x - b_max.x), 0.0)
	var dy := maxf(maxf(b_min.y - a_max.y, a_min.y - b_max.y), 0.0)
	var dz := maxf(maxf(b_min.z - a_max.z, a_min.z - b_max.z), 0.0)
	return dx * dx + dy * dy + dz * dz


func combat_line_bounds() -> Dictionary:
	return _combat_line_bounds.duplicate()


func combat_line_entry_distance(from: Vector3, to: Vector3, position: Vector3) -> float:
	if _unit == null:
		return INF
	var transform := Transform3D(_unit.global_basis, position)
	var inverse := transform.affine_inverse()
	var local_from := inverse * from
	var local_to := inverse * to
	var nearest := INF
	for hull: Dictionary in _combat_line_hulls:
		var planes: Array = hull["planes"]
		if _inside_convex(local_from, planes):
			continue
		var result: Variant = Geometry3D.segment_intersects_convex(local_from, local_to, planes)
		if result is PackedVector3Array and not (result as PackedVector3Array).is_empty():
			nearest = minf(nearest, from.distance_to(transform * (result as PackedVector3Array)[0]))
	return nearest


func _convex_hull_in_unit_space(
		shape: ConvexPolygonShape3D, shape_transform: Transform3D
	) -> Dictionary:
	var debug_mesh := shape.get_debug_mesh()
	if debug_mesh == null:
		return {}
	var faces: PackedVector3Array = debug_mesh.get_faces()
	if faces.is_empty() or faces.size() % 3 != 0:
		return {}
	var transformed_faces := PackedVector3Array()
	var points := PackedVector3Array()
	var centroid := Vector3.ZERO
	var bounding_radius := 0.0
	for point in faces:
		var local_point := shape_transform * point
		transformed_faces.append(local_point)
		points.append(local_point)
		centroid += local_point
		bounding_radius = maxf(bounding_radius, local_point.length())
	centroid /= transformed_faces.size()
	var planes: Array[Plane] = []
	for index in range(0, transformed_faces.size(), 3):
		var first := transformed_faces[index]
		var second := transformed_faces[index + 1]
		var third := transformed_faces[index + 2]
		if (second - first).cross(third - first).length_squared() <= 0.0000001:
			continue
		var plane := Plane(first, second, third)
		if plane.distance_to(centroid) > 0.0:
			plane = Plane(-plane.normal, -plane.d)
		planes.append(plane)
	if planes.is_empty():
		return {}
	var triangles: Array[PackedVector3Array] = []
	var face_bounds: Array[AABB] = []
	var hull_min := Vector3(INF, INF, INF)
	var hull_max := Vector3(-INF, -INF, -INF)
	for point in points:
		hull_min = hull_min.min(point)
		hull_max = hull_max.max(point)
	for index in range(0, transformed_faces.size(), 3):
		var a := transformed_faces[index]
		var b := transformed_faces[index + 1]
		var c := transformed_faces[index + 2]
		if (b - a).cross(c - a).length_squared() > 0.0000001:
			triangles.append(PackedVector3Array([a, b, c]))
			var face_min := a.min(b).min(c)
			var face_max := a.max(b).max(c)
			face_bounds.append(AABB(face_min, face_max - face_min))
	return {"planes": planes, "bounding_radius": bounding_radius, "points": points,
		"faces": triangles, "face_bounds": face_bounds, "min": hull_min, "max": hull_max}


func _inside_convex(point: Vector3, planes: Array) -> bool:
	for plane: Plane in planes:
		if plane.distance_to(point) > 0.00001:
			return false
	return not planes.is_empty()


func sources() -> Array[Node3D]:
	if _unit == null:
		return []
	return AuthoredModelScript.collision_sources(_visual_root(), SOURCE_PREFERENCE)


## Local avoidance uses discs, while authored unit volumes may be long boxes.
## The smaller horizontal half-extent is the stable body width: using the long
## axis would leave vehicle-sized gaps beside every tank, while the rules-only
## radius is small enough for infantry to run visibly through their hulls.
func collision_radius(fallback: float) -> float:
	var extents := half_extents()
	return maxf(fallback, minf(extents.x, extents.y))


## Long vehicles are represented as rounded capsules for navigation.
## `collision_radius` above is their cross-section and remains the right
## unit/unit spacing. Around static terrain, however, a freely turning capsule
## needs its complete rotation envelope: otherwise the centre path clears a
## building while the harvester's nose and tail still sweep through its cells.
func rotation_radius(fallback: float) -> float:
	var extents := half_extents()
	return maxf(fallback, maxf(extents.x, extents.y))


func half_extents() -> Vector2:
	# Lightweight gameplay test doubles intentionally omit the converted visual
	# hierarchy; in that case the rules-derived fallback remains authoritative.
	if _unit == null or _visual_root() == null:
		return Vector2.ZERO
	var maximum_x := 0.0
	var maximum_z := 0.0
	var to_unit := _unit.global_transform.affine_inverse()
	for source in sources():
		var points: PackedVector3Array = source.get_meta("collision_points", PackedVector3Array())
		var source_to_unit: Transform3D = to_unit * source.global_transform
		for point in points:
			var local_point: Vector3 = source_to_unit * point
			maximum_x = maxf(maximum_x, absf(local_point.x))
			maximum_z = maxf(maximum_z, absf(local_point.z))
	return Vector2(maximum_x, maximum_z)


func selection_bounds() -> AABB:
	if _unit == null:
		return AABB()
	return AuthoredModelScript.selection_bounds(_visual_root(), _unit)


func _visual_root() -> Node3D:
	var visual_root: Node3D = _unit.visual_root
	return visual_root
