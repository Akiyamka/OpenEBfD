class_name UnitTerrainAlignment
extends RefCounted

## Keeps a unit's body on the terrain and its rendered model tilted to the
## slope, plus the hull yaw turning that shares the same body basis.
##
## Owns no model nodes — only three Basis/Vector3 values and the rest pose of
## `visual_root`, which survives a mid-life replace_visual_scene() because the
## root node itself is never swapped, only its children. That is why this
## module needs no attach/detach lifecycle: there is nothing here that a
## handed-off corpse subtree could keep alive.

const TerrainProbeScript := preload("res://scripts/world/terrain_probe.gd")
const SpatialOrientationScript := preload("res://scripts/world/spatial_orientation.gd")
const RuleTicksScript := preload("res://scripts/rules/rule_ticks.gd")

const TERRAIN_COLLISION_MASK := 1
const TERRAIN_RAY_HEIGHT := 200.0
const MIN_SLOPE_SPEED_MULTIPLIER := 0.65
const MAX_SLOPE_SPEED_MULTIPLIER := 1.50
const SLOPE_PROBE_DISTANCE := 0.5
const SLOPE_ALIGNMENT_RESPONSE := 10.0
## Turn rates are authored per rules movement update, so the per-second yaw
## step is `turn_rate * MOVEMENT_UPDATES_PER_SECOND`. Kept as a local alias of
## RuleTicks.RULE_MOVEMENT_UPDATES_PER_SECOND -- see that constant's doc
## comment for why it is one declaration shared with UnitFlightController and
## SteeringStabilizer -- so call sites below stay unqualified.
const MOVEMENT_UPDATES_PER_SECOND := RuleTicksScript.RULE_MOVEMENT_UPDATES_PER_SECOND

var _unit: CharacterBody3D
var _visual_root_rest_basis := Basis.IDENTITY
var _visual_slope_target_basis := Basis.IDENTITY
var _last_terrain_normal := Vector3.UP
## Presentation-only roll used by circling aircraft. The gameplay body stays
## upright, so this cannot affect collision, selection, or navigation.
var _visual_flight_bank := 0.0


func configure(unit: CharacterBody3D) -> void:
	_unit = unit
	capture_rest_pose()


func dispose() -> void:
	_unit = null


## The authored resting orientation of `visual_root`, from which every slope
## target is derived. Idempotent: re-reading an already tilted root would bake
## the tilt into the rest pose, so callers take it once, before any alignment.
func capture_rest_pose() -> void:
	if _unit == null:
		return
	var visual_root: Node3D = _unit.visual_root
	if visual_root == null:
		return
	_visual_root_rest_basis = visual_root.transform.basis.orthonormalized()
	_visual_slope_target_basis = _visual_root_rest_basis


func last_terrain_normal() -> Vector3:
	return _last_terrain_normal


func set_flight_bank(angle: float) -> void:
	_visual_flight_bank = angle
	# Rebuild from the captured rest basis; direct visual-root rotation would
	# otherwise be overwritten by the normal slope-alignment pass.
	set_slope_target(_last_terrain_normal)


## A transport anchor is parented below `visual_root` so cargo inherits the
## carrier's presentation pitch/roll.  Converted model roots also carry a
## fixed source-coordinate conversion basis; exposing its inverse here keeps
## that rest conversion from rotating the cargo's gameplay body 180 degrees.
func visual_rest_basis_inverse() -> Basis:
	return _visual_root_rest_basis.inverse()


func terrain_hit_at(position: Vector3) -> Dictionary:
	return TerrainProbeScript.height_hit(
		_unit.get_world_3d(),
		position,
		TERRAIN_COLLISION_MASK,
		[_unit.get_rid()],
		TERRAIN_RAY_HEIGHT
	)


## Extracted so a landed/grounded flying unit (UnitFlightController.advance)
## sits on real terrain/apron height exactly like a ground unit; airborne
## flight phases bypass this entirely (fixed cruise altitude, no terrain-follow).
func snap_body_to_terrain() -> void:
	# Units are moved horizontally, then projected back onto the terrain mesh.
	# Keeping this independent of CharacterBody's floor state lets authored unit
	# collision volumes remain usable for selection while the unit follows every
	# height change in the map instead of retaining its spawn elevation.
	var hit := terrain_hit_at(_unit.global_position)
	if hit.is_empty():
		return

	var snapped := _unit.global_position
	snapped.y = (hit["position"] as Vector3).y
	_unit.global_position = snapped
	set_slope_target(hit.get("normal", Vector3.UP) as Vector3)


## Keeps gameplay orientation, navigation collision and the selection halo
## upright while tilting only the rendered model. A terrain normal uniquely
## determines pitch and roll; projecting the unit's forward vector onto that
## plane preserves its current yaw.
func set_slope_target(terrain_normal: Vector3) -> void:
	_last_terrain_normal = terrain_normal.normalized() \
		if terrain_normal.length_squared() > 0.000001 else Vector3.UP
	if _last_terrain_normal.dot(Vector3.UP) < 0.0:
		_last_terrain_normal = -_last_terrain_normal
	var visual_root: Node3D = _unit.visual_root
	if visual_root == null or not _unit.aligns_visual_to_terrain_slope():
		_visual_slope_target_basis = _visual_root_rest_basis * _flight_bank_basis()
		return

	var unit_basis := _unit.global_transform.basis.orthonormalized()
	var slope_forward := (-unit_basis.z).slide(_last_terrain_normal)
	if slope_forward.length_squared() <= 0.000001:
		slope_forward = unit_basis.x.cross(_last_terrain_normal)
	if slope_forward.length_squared() <= 0.000001:
		_visual_slope_target_basis = _visual_root_rest_basis * _flight_bank_basis()
		return
	slope_forward = slope_forward.normalized()
	var slope_z := -slope_forward
	var slope_x := _last_terrain_normal.cross(slope_z).normalized()
	var slope_basis := Basis(slope_x, _last_terrain_normal, slope_z).orthonormalized()
	_visual_slope_target_basis = (
		unit_basis.inverse() * slope_basis * _visual_root_rest_basis * _flight_bank_basis()
	).orthonormalized()


func _flight_bank_basis() -> Basis:
	# Converted models face local -Z, so roll around that visual forward axis.
	# The flight controller supplies the signed angle.
	return Basis(Vector3.FORWARD, _visual_flight_bank)


## Re-derives the slope target from the last sampled normal. Yaw changes move
## the target even when the ground under the unit has not changed.
func refresh_slope_target() -> void:
	set_slope_target(_last_terrain_normal)


func advance_slope_alignment(delta: float) -> void:
	var visual_root: Node3D = _unit.visual_root
	if visual_root == null or delta <= 0.0:
		return
	var blend := 1.0 - exp(-SLOPE_ALIGNMENT_RESPONSE * delta)
	visual_root.transform.basis = visual_root.transform.basis.orthonormalized().slerp(
		_visual_slope_target_basis, clampf(blend, 0.0, 1.0)
	).orthonormalized()


func slope_speed_multiplier(direction: Vector3, delta: float) -> float:
	if _unit.flight_is_airborne_phase():
		return 1.0
	var current_hit := terrain_hit_at(_unit.global_position)
	if current_hit.is_empty():
		return 1.0

	var probe_distance := maxf(float(_unit.move_speed) * delta, SLOPE_PROBE_DISTANCE)
	var ahead := _unit.global_position + direction * probe_distance
	var ahead_hit := terrain_hit_at(ahead)
	if ahead_hit.is_empty():
		return 1.0

	var current_position: Vector3 = current_hit["position"]
	var ahead_position: Vector3 = ahead_hit["position"]
	var slope := (ahead_position.y - current_position.y) / probe_distance
	if slope > 0.0:
		return maxf(1.0 - slope * 0.65, MIN_SLOPE_SPEED_MULTIPLIER)
	return minf(1.0 - slope * 0.75, MAX_SLOPE_SPEED_MULTIPLIER)


## Rotates the hull toward `direction` by at most one tick's worth of yaw.
## Returns true once the unit faces it (immediately when it already does).
func turn_toward(direction: Vector3, delta: float) -> bool:
	var horizontal_direction := Vector3(direction.x, 0.0, direction.z)
	if horizontal_direction.length_squared() <= 0.000001:
		return true
	horizontal_direction = horizontal_direction.normalized()
	var current_yaw: float = _unit.global_rotation.y
	var target_yaw := SpatialOrientationScript.yaw_facing(horizontal_direction, current_yaw)
	if is_zero_approx(angle_difference(current_yaw, target_yaw)):
		return true
	var turn_rate := float(_unit.turn_rate)
	if turn_rate <= 0.0 or delta <= 0.0:
		return false
	var maximum_step := turn_rate * MOVEMENT_UPDATES_PER_SECOND * delta
	var rotation := _unit.global_rotation
	rotation.y = rotate_toward(current_yaw, target_yaw, maximum_step)
	_unit.global_rotation = rotation
	return is_zero_approx(angle_difference(rotation.y, target_yaw))
