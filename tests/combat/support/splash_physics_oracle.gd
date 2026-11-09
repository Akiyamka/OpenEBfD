extends RefCounted

const CombatRulesScript := preload("res://scripts/combat/combat_rules.gd")
const CombatTargetScript := preload("res://scripts/combat/combat_target.gd")


static func hits(world: World3D, centre: Vector3, radius: float, entity: Object) -> bool:
	var sphere := SphereShape3D.new()
	sphere.radius = radius
	var query := PhysicsShapeQueryParameters3D.new()
	query.shape = sphere
	query.transform = Transform3D(Basis.IDENTITY, centre)
	query.collision_mask = CombatRulesScript.COLLISION_MASK
	query.collide_with_bodies = true
	query.collide_with_areas = true
	for hit in world.direct_space_state.intersect_shape(query, 4096):
		if CombatTargetScript.entity_of(hit.get("collider")) == entity:
			return true
	return false
