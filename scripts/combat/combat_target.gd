class_name CombatTarget
extends RefCounted

const CombatRulesScript := preload("res://scripts/combat/combat_rules.gd")
const EntityQueryScript := preload("res://scripts/world/entity_query.gd")


static func entity_of(collider: Object) -> Object:
	var current := collider as Node
	while current != null:
		if current.has_method("combat_armour_type"):
			return current
		current = current.get_parent()
	return null


static func position_of(target: Variant, origin := Vector3.INF) -> Vector3:
	if target is Vector3:
		return target
	if not target is Object or not is_instance_valid(target):
		return Vector3.INF
	var object := target as Object
	if origin.is_finite() and object.has_method("combat_aim_position_from"):
		var aimed: Variant = object.call("combat_aim_position_from", origin)
		if aimed is Vector3:
			return aimed
	if object.has_method("combat_aim_position"):
		var aimed: Variant = object.call("combat_aim_position")
		if aimed is Vector3:
			return aimed
	return (object as Node3D).global_position if object is Node3D else Vector3.INF


static func is_alive(target: Variant) -> bool:
	if not target is Object or not is_instance_valid(target):
		return false
	if target is Node and (target as Node).is_queued_for_deletion():
		return false
	return not target.has_method("combat_is_alive") or bool(target.call("combat_is_alive"))


static func hit_radius(
	target: Object,
	fallback: float = CombatRulesScript.DEFAULT_TARGET_HIT_RADIUS
	) -> float:
	if target != null and target.has_method("combat_hit_radius"):
		return maxf(float(target.call("combat_hit_radius")), fallback)
	return fallback


## Ownership/alliance test shared by the two places that need it for opposite
## reasons: CombatImpactResolver scales a delivered warhead down to
## FriendlyDamageAmount, and CombatLineOfFire decides whether a shot should be
## held rather than put through a squadmate's back. Keeping one rule here stops
## the two from drifting apart -- a shot held on a body the resolver would then
## have billed at full damage is the failure mode that matters.
static func are_friendly(source: Object, target: Object) -> bool:
	if source == null or not is_instance_valid(source) or target == null:
		return false
	if source == target:
		return true
	var source_owner: Variant = owner_player_id_of(source)
	var target_owner: Variant = owner_player_id_of(target)
	if source_owner == null or target_owner == null:
		return false
	if source.has_method("is_allied_with"):
		return bool(source.call("is_allied_with", int(target_owner)))
	# -1 is the neutral owner. Distinct neutral objects are not an allied team.
	return int(source_owner) >= 0 and int(source_owner) == int(target_owner)


## Null rather than -1 for "no owner at all", so a neutral object (-1) and an
## unowned one stay distinguishable to are_friendly().
static func owner_player_id_of(object: Object) -> Variant:
	if object == null or not is_instance_valid(object):
		return null
	if object.has_method("combat_owner_player_id"):
		return object.call("combat_owner_player_id")
	var owner_id := EntityQueryScript.owner_id_of(object)
	return owner_id if owner_id >= 0 else null


static func collision_rids(target: Object) -> Array[RID]:
	var result: Array[RID] = []
	_collect_collision_rids(target, result)
	return result


static func _collect_collision_rids(object: Object, result: Array[RID]) -> void:
	if object == null or not is_instance_valid(object):
		return
	if object is CollisionObject3D:
		result.append((object as CollisionObject3D).get_rid())
	if object is Node:
		for child in (object as Node).get_children():
			_collect_collision_rids(child, result)
