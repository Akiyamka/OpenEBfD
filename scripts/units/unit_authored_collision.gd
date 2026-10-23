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
	return _combat_line_hulls.duplicate(true)


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
	return {"planes": planes, "bounding_radius": bounding_radius, "points": points}


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
