class_name UnitPushAside
extends RefCounted

## Units caught inside a newly placed building's footprint are shoved out to
## the nearest footprint edge (least total displacement) rather than blocking
## placement or getting crushed.


## Deployed combat units cannot leave a building footprint. The normal
## building-command path refuses them before spawning; wall placement still
## reaches this shove path and deliberately leaves them in place for now.
static func is_immobile(unit: Node) -> bool:
	return (
		(unit.has_method("is_deployed") and bool(unit.call("is_deployed")))
		or (unit.has_method("is_deploying") and bool(unit.call("is_deploying")))
	)


static func is_inside_footprint(
		position: Vector3, footprint_world_start: Vector3, footprint_world_end: Vector3
	) -> bool:
	var min_x := minf(footprint_world_start.x, footprint_world_end.x)
	var max_x := maxf(footprint_world_start.x, footprint_world_end.x)
	var min_z := minf(footprint_world_start.z, footprint_world_end.z)
	var max_z := maxf(footprint_world_start.z, footprint_world_end.z)
	return position.x >= min_x and position.x <= max_x and position.z >= min_z and position.z <= max_z


static func push_units_out_of_footprint(
		units: Array,
		footprint_world_start: Vector3,
		footprint_world_end: Vector3,
		margin: float
	) -> void:
	if units.is_empty():
		return

	var min_x := minf(footprint_world_start.x, footprint_world_end.x)
	var max_x := maxf(footprint_world_start.x, footprint_world_end.x)
	var min_z := minf(footprint_world_start.z, footprint_world_end.z)
	var max_z := maxf(footprint_world_start.z, footprint_world_end.z)

	for unit in units:
		if not (unit is Node3D):
			continue
		if is_immobile(unit):
			continue
		var position: Vector3 = unit.simulation_position()
		if not is_inside_footprint(position, footprint_world_start, footprint_world_end):
			continue

		var pushed := _push_destination(position, min_x, max_x, min_z, max_z, margin)
		# Duck-typed like the stop_at_current_position() call below, and for
		# the same reason this function only ever checked `unit is Node3D`
		# above rather than `unit is Unit`: routing through
		# set_simulation_position() (see that method's own doc comment) keeps
		# a real Unit's write going through the running match's
		# SimEntityState, while a plain Node3D with no such method -- nothing
		# in this project puts one in the "units" group today, but this
		# function has never assumed otherwise -- still gets shoved directly.
		if unit.has_method("set_simulation_position"):
			unit.call("set_simulation_position", pushed)
		else:
			unit.global_position = pushed
		if unit.has_method("stop_at_current_position"):
			unit.call("stop_at_current_position")


static func _push_destination(
		position: Vector3, min_x: float, max_x: float, min_z: float, max_z: float, margin: float
	) -> Vector3:
	var dist_to_min_x := position.x - min_x
	var dist_to_max_x := max_x - position.x
	var dist_to_min_z := position.z - min_z
	var dist_to_max_z := max_z - position.z
	var smallest := minf(dist_to_min_x, minf(dist_to_max_x, minf(dist_to_min_z, dist_to_max_z)))

	if smallest == dist_to_min_x:
		return Vector3(min_x - margin, position.y, position.z)
	if smallest == dist_to_max_x:
		return Vector3(max_x + margin, position.y, position.z)
	if smallest == dist_to_min_z:
		return Vector3(position.x, position.y, min_z - margin)
	return Vector3(position.x, position.y, max_z + margin)
