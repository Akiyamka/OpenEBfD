extends RefCounted

const CombatTargetScript := preload("res://scripts/combat/combat_target.gd")
const SimEntityRegistryScript := preload("res://scripts/sim/entity_registry.gd")
const EntityNodeIndexScript := preload("res://scripts/match/entity_node_index.gd")
const SimEntityStateScript := preload("res://scripts/sim/entity_state.gd")
const MatchUnitSpatialIndexScript := preload("res://scripts/match/match_unit_spatial_index.gd")

const MAX_HITS := 64
const MAX_EXCLUDED_RIDS := 4096


## The Match-owned index is only a broadphase. Every returned ID is checked
## against live admission and the tick store before its cached hull is probed.
static func collect(
		projectile: Node3D, match_node: Node, index: EntityNodeIndexScript,
		state: SimEntityStateScript, spatial: MatchUnitSpatialIndexScript,
		from: Vector3, to: Vector3, radius: float,
		bullet: Variant, source: Object, physics_excludes: Array[RID], mask: int,
		hits: Array[Dictionary], query_adapter: Object = null
	) -> bool:
	var length := from.distance_to(to)
	var effective_radius := minf(radius, length * 0.5)
	var ids: PackedInt32Array = spatial.padded_segment_candidates(from, to, effective_radius)
	var registry: SimEntityRegistryScript = index.registry()
	for id in ids:
		if not registry.is_alive(id) or registry.kind_of(id) != SimEntityRegistryScript.Kind.UNIT \
		or not state.has_position(id):
			continue
		var unit: Node = index.node_for(id)
		if unit == null or not _is_unit(unit):
			continue
		var carried: bool = unit.is_carried()
		if not carried and unit is CollisionObject3D:
			physics_excludes.append((unit as CollisionObject3D).get_rid())
		if not unit.is_in_group(&"sim_units") \
		or not (unit == match_node or match_node.is_ancestor_of(unit)) \
		or carried \
		or unit.get_meta("combat_ignore", false) or unit == source \
		or not bullet.can_hit(unit):
			continue
		var contact: Dictionary = unit.projectile_hull_contact(from, to, state.position(id), effective_radius)
		if contact.is_empty() or not contact.get("hit", false):
			continue
		var aim_centre := CombatTargetScript.position_of(unit, from) \
			if radius > 0.0 else Vector3.ZERO
		var impact: Vector3 = aim_centre if radius > 0.0 else contact["position"]
		hits.append({"collider": unit, "position": impact, "entry": float(contact.get("entry", INF)),
			"rank": from.distance_squared_to(aim_centre),
			"id": id, "unit": true})
	var physical := _physical_hits(projectile, match_node, index, from, to, effective_radius,
		bullet, source, physics_excludes, mask, hits, query_adapter)
	if not physical:
		hits.clear()
		return false
	if hits.size() <= 1:
		return true
	if radius > 0.0:
		hits.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
			if a["rank"] != b["rank"]:
				return a["rank"] < b["rank"]
			return a["id"] < b["id"]
		)
	else:
		hits.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
			if a["entry"] != b["entry"]:
				return a["entry"] < b["entry"]
			if a["unit"] != b["unit"]:
				return not a["unit"]
			return a["id"] < b["id"]
		)
	if hits.size() > MAX_HITS:
		hits.resize(MAX_HITS)
	return true


static func _physical_hits(
		projectile: Node3D, match_node: Node, index: EntityNodeIndexScript, from: Vector3,
		to: Vector3, radius: float, bullet: Variant, source: Object,
		excludes: Array[RID], mask: int, hits: Array[Dictionary], query_adapter: Object
	) -> bool:
	var seen: Dictionary = {}
	var shape_query: PhysicsShapeQueryParameters3D
	if radius > 0.0:
		var segment := to - from
		var shape := CapsuleShape3D.new()
		shape.radius = radius
		shape.height = segment.length()
		shape_query = PhysicsShapeQueryParameters3D.new()
		shape_query.shape = shape
		shape_query.transform = Transform3D(Basis(Quaternion(Vector3.UP, segment.normalized())), (from + to) * 0.5)
		shape_query.collision_mask = mask
		shape_query.collide_with_areas = true
		shape_query.collide_with_bodies = true
	while true:
		var page: Array[Dictionary] = []
		if shape_query != null:
			shape_query.exclude = excludes
			page = query_adapter.call("shape_hits", shape_query, MAX_HITS) \
				if query_adapter != null else projectile.get_world_3d().direct_space_state.intersect_shape(shape_query, MAX_HITS)
		else:
			var ray := PhysicsRayQueryParameters3D.create(from, to, mask, excludes)
			ray.collide_with_areas = true
			ray.collide_with_bodies = true
			ray.hit_from_inside = true
			var hit: Dictionary = query_adapter.call("ray_hit", ray) \
				if query_adapter != null else projectile.get_world_3d().direct_space_state.intersect_ray(ray)
			if not hit.is_empty():
				page.append(hit)
		if page.is_empty():
			return true
		for hit in page:
			var rid: RID = hit.get("rid", RID())
			if not rid.is_valid() or seen.has(rid) or seen.size() >= MAX_EXCLUDED_RIDS:
				return false
			seen[rid] = true
			excludes.append(rid)
			var collider := hit.get("collider") as CollisionObject3D
			if collider == null or collider.get_meta("combat_ignore", false):
				continue
			var entity := CombatTargetScript.entity_of(collider)
			if entity != null and entity == source:
				continue
			if entity != null and _is_unit(entity):
				var unit := entity as Node
				var id: int = index.id_for(unit)
				if not unit.is_carried() or id == 0 or not index.registry().is_alive(id) \
				or not (unit == match_node or match_node.is_ancestor_of(unit)):
					continue
			if entity != null and not bullet.can_hit(entity):
				continue
			if radius > 0.0 and entity == null:
				continue
			if entity != null:
				var already_hit := false
				for prior in hits:
					if CombatTargetScript.entity_of(prior["collider"]) == entity:
						already_hit = true
						break
				if already_hit:
					continue
			var position: Vector3 = CombatTargetScript.position_of(entity, from) \
				if radius > 0.0 else Vector3(hit["position"])
			var id: int = index.id_for(entity as Node) if entity is Node else 0
			hits.append({"collider": collider, "position": position,
				"entry": from.distance_to(position), "rank": from.distance_squared_to(position),
				"id": id if id > 0 else 2147483647, "unit": false})
	return false


static func _is_unit(entity: Object) -> bool:
	return entity is CharacterBody3D and entity.has_method("projectile_hull_contact") \
		and entity.has_method("is_carried")
