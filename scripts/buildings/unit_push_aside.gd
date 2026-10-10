class_name UnitPushAside
extends RefCounted

## Footprint predicates the placement unit queries share. Nothing here moves a
## unit: no building spawn displaces one, because every caller asks
## has_any_unit_in_footprint() first and defers, waits or refuses.


## Deployed combat units cannot leave a building footprint. The immobile
## placement query refuses on such a unit at once instead of waiting for it.
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
