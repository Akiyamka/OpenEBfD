extends RefCounted

const CombatTargetScript := preload("res://scripts/combat/combat_target.gd")
const SimEntityRegistryScript := preload("res://scripts/sim/entity_registry.gd")
const MAX_PAGE := 256
const MAX_EXCLUDED_RIDS := 4096


static func collect(
		world_context: Node, match_node: Node, index: RefCounted, state: RefCounted,
		spatial: RefCounted, centre: Vector3, radius: float, bullet: Variant,
		source: Object, direct_target: Object, distance_fn: Callable, mask: int,
		query_adapter: Object = null
	) -> Dictionary:
	var entries: Array[Dictionary] = []
	var excludes: Array[RID] = []
	var seen_entity_id: Dictionary = {}
	if direct_target is Node and is_instance_valid(direct_target):
		var direct_node := direct_target as Node
		var direct_id: int = index.id_for(direct_node)
		seen_entity_id[direct_id if direct_id > 0 else direct_node.get_instance_id()] = true
	var ids: PackedInt32Array = spatial.rectangle_candidates(
		Vector2(centre.x - radius, centre.z - radius),
		Vector2(centre.x + radius, centre.z + radius))
	var registry = index.registry()
	for id in ids:
		if not registry.is_alive(id) or registry.kind_of(id) != SimEntityRegistryScript.Kind.UNIT \
		or not state.has_position(id) or not state.has_combat_line_bounds(id):
			continue
		var unit: Node = index.node_for(id)
		if unit == null or not _owned_unit(unit, match_node):
			continue
		if unit is CollisionObject3D:
			excludes.append((unit as CollisionObject3D).get_rid())
		var stored_carried: bool = state.has_combat_line_carried(id) and state.combat_line_carried(id)
		if stored_carried != unit.is_carried():
			push_error("SplashUnitCollision: carried flag disagreement for unit %d" % id)
			continue
		if seen_entity_id.has(id) or unit == source or unit.get_meta("combat_ignore", false) \
		or not bullet.can_hit(unit) \
		or not CombatTargetScript.is_alive(unit):
			continue
		var distance: float = distance_fn.call(unit, centre)
		if distance > radius + 0.0001:
			continue
		var contact: Dictionary = unit.projectile_hull_contact(
			centre - Vector3.UP * radius, centre + Vector3.UP * radius,
			state.position(id), radius)
		if contact.is_empty() or not contact.get("hit", false):
			continue
		seen_entity_id[id] = true
		entries.append({"target": unit, "id": id, "distance": distance})

	if world_context == null or not is_instance_valid(world_context) \
	or not world_context.is_inside_tree() or not world_context is Node3D:
		return {"ok": true, "entries": entries}
	var world := (world_context as Node3D).get_world_3d()
	if world == null:
		return {"ok": true, "entries": entries}
	var sphere := SphereShape3D.new()
	sphere.radius = radius
	var query := PhysicsShapeQueryParameters3D.new()
	query.shape = sphere
	query.transform = Transform3D(Basis.IDENTITY, centre)
	query.collision_mask = mask
	query.collide_with_areas = true
	query.collide_with_bodies = true
	var seen_rids: Dictionary = {}
	while true:
		query.exclude = excludes
		var page: Array[Dictionary] = query_adapter.call("shape_hits", query, MAX_PAGE) \
			if query_adapter != null else world.direct_space_state.intersect_shape(query, MAX_PAGE)
		if page.is_empty():
			break
		for hit in page:
			var rid: RID = hit.get("rid", RID())
			if not rid.is_valid() or seen_rids.has(rid) or seen_rids.size() >= MAX_EXCLUDED_RIDS:
				push_error("SplashUnitCollision: invalid, repeated, or exhausted physics RID page")
				return {"ok": false, "entries": []}
			seen_rids[rid] = true
			excludes.append(rid)
			var collider: Object = hit.get("collider") as Object
			if collider == null or not is_instance_valid(collider):
				continue
			var entity: Object = CombatTargetScript.entity_of(collider)
			if entity == null or entity == source or not is_instance_valid(entity) \
			or not entity is Node or (entity as Node).get_meta("combat_ignore", false):
				continue
			var node := entity as Node
			if _foreign_match(node, match_node):
				continue
			if _is_unit(node):
				var unit_id: int = index.id_for(node)
				if unit_id <= 0 or not registry.is_alive(unit_id) \
				or registry.kind_of(unit_id) != SimEntityRegistryScript.Kind.UNIT \
				or not _owned_unit(node, match_node):
					continue
				continue
			if not bullet.can_hit(entity) or not CombatTargetScript.is_alive(entity):
				continue
			var distance: float = distance_fn.call(entity, centre)
			if distance > radius + 0.0001:
				continue
			var id: int = index.id_for(node)
			var key: int = id if id > 0 else node.get_instance_id()
			if seen_entity_id.has(key):
				continue
			seen_entity_id[key] = true
			entries.append({"target": entity, "id": id if id > 0 else 2147483647,
				"distance": distance})
	entries.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return int(a["id"]) < int(b["id"]))
	return {"ok": true, "entries": entries}


static func _is_unit(node: Node) -> bool:
	return node is CharacterBody3D and node.has_method("projectile_hull_contact") \
		and node.has_method("is_carried")


static func _owned_unit(node: Node, match_node: Node) -> bool:
	return _is_unit(node) and node.is_in_group(&"sim_units") \
		and (node == match_node or match_node.is_ancestor_of(node))


static func _foreign_match(node: Node, match_node: Node) -> bool:
	var ancestor: Node = node
	while ancestor != null:
		if ancestor.is_in_group(&"match_root"):
			return ancestor != match_node
		ancestor = ancestor.get_parent()
	return false
