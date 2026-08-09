class_name UnitAuthoredCollision
extends RefCounted

## Everything a unit derives from the collision volumes baked into its converted
## model: the physics shapes added to the body, the horizontal extents the
## navigation system asks for, and the selection bounds combat aims at.
##
## Owns no model nodes and caches nothing — every query walks `visual_root`
## fresh, so a runtime model swap (replace_visual_scene) needs no invalidation
## and a handed-off corpse subtree cannot be kept alive through this module.
## That is also why it needs no attach/detach lifecycle, only `configure`.

const AuthoredModelScript := preload("res://scripts/world/authored_model.gd")

## The converted models' unnamed collision object. Units that have one use it;
## the `slct` selection volumes are the fallback for models that do not.
const COLLISION_OBJECT_NAME := "#~~0"
const SOURCE_PREFERENCE := [
	{"name": COLLISION_OBJECT_NAME, "prefix": false},
	{"name": "slct", "prefix": true},
]

var _unit: CharacterBody3D


func configure(unit: CharacterBody3D) -> void:
	_unit = unit


func dispose() -> void:
	_unit = null


## Adds one CollisionShape3D per authored collision volume directly to the body.
## Called once from Unit._ready(); the unit keeps collision_mask at 0, so these
## shapes only serve mouse-picking rays and combat queries, never terrain
## contact (see the comment at the call site).
func add_body_shapes() -> void:
	if _unit == null:
		return
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
