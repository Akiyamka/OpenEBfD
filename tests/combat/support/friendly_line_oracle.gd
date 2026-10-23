class_name FriendlyLineOracle
extends RefCounted

## Test-only copy of the pre-AO1 body-ray contract. It deliberately remains a
## physics oracle so the stationary and broadphase-lag checks can demonstrate
## the old/new distinction rather than deriving both answers from the new hull
## implementation.

const CombatTargetScript := preload("res://scripts/combat/combat_target.gd")

const BLOCKER_COLLISION_MASK := 3
const TERRAIN_COLLISION_LAYER := 1
const MAX_PIERCED_COLLIDERS := 8
const TARGET_CLEARANCE_WORLD := 0.5


static func friendly_on_line(
		world: World3D, from: Vector3, to: Vector3, shooter: Object, ignored: Array = []
	) -> bool:
	if world == null or shooter == null or not is_instance_valid(shooter) \
	or not from.is_finite() or not to.is_finite():
		return false
	var offset := to - from
	var distance := offset.length()
	if distance <= TARGET_CLEARANCE_WORLD:
		return false
	var probe_end := from + offset / distance * (distance - TARGET_CLEARANCE_WORLD)
	var excludes: Array[RID] = []
	for candidate: Variant in ignored:
		excludes.append_array(CombatTargetScript.collision_rids(candidate as Object))
	excludes.append_array(CombatTargetScript.collision_rids(shooter))
	for index in MAX_PIERCED_COLLIDERS:
		var query := PhysicsRayQueryParameters3D.create(from, probe_end, BLOCKER_COLLISION_MASK, excludes)
		query.collide_with_areas = false
		query.collide_with_bodies = true
		# State the pre-AO1 default explicitly: this must not become dependent on
		# an engine-default change while characterizing start-inside behavior.
		query.hit_from_inside = false
		var hit := world.direct_space_state.intersect_ray(query)
		if hit.is_empty():
			return false
		var rid: RID = hit.get("rid", RID())
		if not rid.is_valid():
			return false
		var body := hit.get("collider") as CollisionObject3D
		if body != null and not bool(body.get_meta("combat_ignore", false)):
			if (body.collision_layer & TERRAIN_COLLISION_LAYER) != 0:
				return false
			var entity := CombatTargetScript.entity_of(body)
			if entity != null:
				if entity.has_method("combat_hull"):
					return false
				if entity != shooter and CombatTargetScript.are_friendly(shooter, entity):
					return true
		excludes.append(rid)
	return false
