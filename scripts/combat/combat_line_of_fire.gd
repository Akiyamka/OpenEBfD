class_name CombatLineOfFire
extends RefCounted

const CombatTargetScript := preload("res://scripts/combat/combat_target.gd")
const CombatRulesScript := preload("res://scripts/combat/combat_rules.gd")

## Decides whether a flat-flying shot can reach a point at all. CombatProjectile
## sweeps terrain and building colliders while it travels, so a target that sits
## inside weapon range but behind a cliff shoulder or a building is unhittable
## from the shooter's current position: the shell detonates on the obstacle
## instead. Order handling asks this before firing so the unit repositions.
##
## Units are pierced rather than treated as obstacles. They move on their own,
## and a passing vehicle crossing the line must not make an engaged unit
## abandon a target it can already hit.

const BLOCKER_COLLISION_MASK := CombatRulesScript.COLLISION_MASK
const TERRAIN_COLLISION_LAYER := 1
## An attack-ground aim point lies on the terrain surface itself. Stopping the
## probe short of it keeps the destination ground from counting as its own
## obstacle; one rules tile spans 2.0 world units, so this is a quarter tile.
const TARGET_CLEARANCE_WORLD := 0.5
const MAX_PIERCED_COLLIDERS := 8


static func is_clear(
		world: World3D,
		from: Vector3,
		to: Vector3,
		ignored: Array = []
	) -> bool:
	if world == null or not from.is_finite() or not to.is_finite():
		return true
	var offset := to - from
	var distance := offset.length()
	if distance <= TARGET_CLEARANCE_WORLD:
		return true
	var probe_end := from + offset / distance * (distance - TARGET_CLEARANCE_WORLD)
	var excludes: Array[RID] = []
	for candidate: Variant in ignored:
		excludes.append_array(CombatTargetScript.collision_rids(candidate as Object))
	for index in MAX_PIERCED_COLLIDERS:
		var query := PhysicsRayQueryParameters3D.create(
			from, probe_end, BLOCKER_COLLISION_MASK, excludes
		)
		query.collide_with_areas = false
		query.collide_with_bodies = true
		var hit := world.direct_space_state.intersect_ray(query)
		if hit.is_empty():
			return true
		var rid: RID = hit.get("rid", RID())
		if not rid.is_valid():
			return true
		if _obstructs(hit.get("collider") as Object):
			return false
		excludes.append(rid)
	return true


## Whether a friendly body stands on the shot's path.
##
## `is_clear` above deliberately pierces units, which is the right answer to
## "will the shell arrive" -- but it is the wrong answer to "should this shot be
## taken". Nothing else stops a rear rank from firing through its own front
## rank, and CombatImpactResolver then bills the front rank the warhead's
## FriendlyDamageAmount share. Firing code asks this separately so it can hold
## the shot (and, given time, step off the line) instead.
##
## Terrain and buildings end the scan rather than answering it: the shell stops
## on them anyway, and `is_clear` has already rejected such a shot for its own
## reasons. Lobbing weapons never reach here -- their caller skips them.
static func friendly_on_line(
		world: World3D,
		from: Vector3,
		to: Vector3,
		shooter: Object,
		ignored: Array = []
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
		var query := PhysicsRayQueryParameters3D.create(
			from, probe_end, BLOCKER_COLLISION_MASK, excludes
		)
		query.collide_with_areas = false
		query.collide_with_bodies = true
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
				# A building already stops the shell (see `_obstructs`), so it
				# ends the scan whether or not it happens to be friendly.
				if entity.has_method("combat_hull"):
					return false
				if entity != shooter and CombatTargetScript.are_friendly(shooter, entity):
					return true
		excludes.append(rid)
	return false


static func _obstructs(collider: Object) -> bool:
	var body := collider as CollisionObject3D
	if body == null or bool(body.get_meta("combat_ignore", false)):
		return false
	if (body.collision_layer & TERRAIN_COLLISION_LAYER) != 0:
		return true
	# Buildings and walls share the entity collision layer with units. The
	# footprint hull they expose identifies them from combat code without
	# depending on the buildings module.
	var entity := CombatTargetScript.entity_of(body)
	return entity != null and entity.has_method("combat_hull")
