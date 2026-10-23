extends RefCounted


class FakeCombatTarget extends RefCounted:
	var armour_type: StringName
	var airborne := false
	var damage_taken := 0.0
	var position := Vector3.ZERO
	var alive := true
	var hit_radius := 0.25
	var owner_player_id := 2
	var accepted_effects: Array[StringName] = []
	var received_effects: Array[StringName] = []
	var received_effect_contexts: Array[Dictionary] = []

	func _init(target_armour: StringName, target_airborne := false) -> void:
		armour_type = target_armour
		airborne = target_airborne

	func combat_armour_type() -> StringName:
		return armour_type

	func combat_is_airborne() -> bool:
		return airborne

	func combat_aim_position() -> Vector3:
		return position

	func combat_is_alive() -> bool:
		return alive

	func combat_hit_radius() -> float:
		return hit_radius

	func is_enemy_of(player_id: int) -> bool:
		return owner_player_id != player_id

	func take_damage(amount: float, _death_cause: StringName = &"") -> void:
		damage_taken += amount

	func combat_owner_player_id() -> int:
		return owner_player_id

	func combat_apply_bullet_effect(effect: StringName, context: Dictionary) -> bool:
		received_effects.append(effect)
		received_effect_contexts.append(context)
		return effect in accepted_effects


class PhysicsCombatTarget extends StaticBody3D:
	var armour_type: StringName = &"None"
	var damage_taken := 0.0
	var owner_player_id := 2
	var alive := true
	# Immutable after _init: combat_line_hulls is cached from this radius.
	var hit_radius := 0.5
	var has_authoritative_position := false
	var authoritative_position := Vector3.ZERO
	var carried := false

	## Slice R6 migrated CombatTargetAcquisition's candidate distances onto
	## simulation_position(). This double stands in for a Unit or a Building
	## there, and neither a Match nor a store exists in these suites, so it
	## answers the same way Unit.simulation_position() does when there is no
	## store to ask -- with the node. The third double in this program to need
	## this; R3 fixed two in tests/navigation and tests/match, R4 one in
	## tests/units.
	func simulation_position() -> Vector3:
		return authoritative_position if has_authoritative_position else global_position


	func is_carried() -> bool:
		return carried


	## Test-only convex body geometry matching the line-facing box around this
	## stand-in. Runtime code accepts only convex face sets; spheres remain
	## physics fixtures, never a production geometry branch.
	func combat_line_hulls() -> Array[Dictionary]:
		var radius := hit_radius
		return [{
			"bounding_radius": radius * sqrt(3.0),
			"planes": [
				Plane(Vector3.RIGHT, radius), Plane(Vector3.LEFT, radius),
				Plane(Vector3.UP, radius), Plane(Vector3.DOWN, radius),
				Plane(Vector3.FORWARD, radius), Plane(Vector3.BACK, radius),
			],
		}]


	func combat_line_bounds() -> Dictionary:
		return {"radius": hit_radius + 0.01, "min_y": -hit_radius - 0.01, "max_y": hit_radius + 0.01}


	func combat_line_entry_distance(from: Vector3, to: Vector3, stored_position: Vector3) -> float:
		var radius := hit_radius
		var offset := to - from
		var local_from := from - stored_position
		if local_from.length_squared() <= radius * radius:
			return INF
		var a := offset.length_squared()
		var b := 2.0 * local_from.dot(offset)
		var c := local_from.length_squared() - radius * radius
		var discriminant := b * b - 4.0 * a * c
		if discriminant < 0.0:
			return INF
		var fraction := (-b - sqrt(discriminant)) / (2.0 * a)
		return from.distance_to(to) * fraction if fraction >= 0.0 and fraction <= 1.0 else INF


	func _init(world_position: Vector3, radius := 0.5) -> void:
		position = world_position
		hit_radius = radius
		collision_layer = 2
		collision_mask = 0
		var collision := CollisionShape3D.new()
		var sphere := SphereShape3D.new()
		sphere.radius = radius
		collision.shape = sphere
		add_child(collision)

	func combat_armour_type() -> StringName:
		return armour_type

	func combat_is_airborne() -> bool:
		return false

	func combat_aim_position() -> Vector3:
		return global_position

	func combat_is_alive() -> bool:
		return alive

	func combat_hit_radius() -> float:
		return hit_radius

	func is_enemy_of(player_id: int) -> bool:
		return owner_player_id != player_id

	func combat_owner_player_id() -> int:
		return owner_player_id

	func take_damage(amount: float, _death_cause: StringName = &"") -> void:
		damage_taken += amount


class PhysicsBuildingBlocker extends PhysicsCombatTarget:
	func combat_hull() -> PackedVector2Array:
		return PackedVector2Array([
			Vector2(-hit_radius, -hit_radius),
			Vector2(hit_radius, -hit_radius),
			Vector2(hit_radius, hit_radius),
			Vector2(-hit_radius, hit_radius),
		])


class CombatSource extends RefCounted:
	var owner_player_id := 1

	func combat_owner_player_id() -> int:
		return owner_player_id
