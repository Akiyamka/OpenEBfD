class_name CombatLineOfFire
extends RefCounted

const CombatTargetScript := preload("res://scripts/combat/combat_target.gd")
const CombatRulesScript := preload("res://scripts/combat/combat_rules.gd")
const CombatLineGridScript := preload("res://scripts/sim/combat_line_grid.gd")
const MatchLookupScript := preload("res://scripts/match/match_lookup.gd")

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
const MAX_FRIENDLY_LINE_PIERCES := 4096

static var _snapshot_tree_id := 0
static var _snapshot_match_id := 0
static var _snapshot_tick := -1
static var _snapshot_revision := -1
static var _snapshot_grid := CombatLineGridScript.new()
static var _snapshot_index
static var _snapshot_state
static var _snapshot_has_carried := false
static var _snapshot_build_ids := PackedInt32Array()
static var _shooter_matches: Dictionary = {}

# The Match path is synchronous: a turret cannot recursively ask the same
# line question. Reusing these arrays removes the hot short-lived allocations
# without exposing them outside this call.
static var _scratch_local_rids: Array[RID] = []
static var _scratch_static_excludes: Array[RID] = []
static var _scratch_carried_excludes: Array[RID] = []


## Test-only observation of the current Match snapshot.  Callers must treat
## the returned grid as read-only: it is reused by every combat query.
static func debug_grid_for_test() -> CombatLineGridScript:
	return _snapshot_grid


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
	var shooter_node := shooter as Node
	if shooter_node == null or not shooter_node.is_inside_tree():
		return _friendly_on_line_legacy(world, from, probe_end, shooter, ignored)
	var tree := shooter_node.get_tree()
	if tree == null:
		return _friendly_on_line_legacy(world, from, probe_end, shooter, ignored)
	var match_node := _match_for_shooter(shooter_node)
	if match_node != null:
		_ensure_match_snapshot(tree, match_node)
		var local_ids := _snapshot_grid.query_segment(from, probe_end)
		if local_ids.is_empty() and not _snapshot_has_carried:
			return false
		_scratch_local_rids.clear()
		var earliest_entry := INF
		for id in local_ids:
			var candidate: Object = _snapshot_index.node_for(id)
			if candidate == null or not is_instance_valid(candidate):
				continue
			var body := candidate as CollisionObject3D
			if body != null:
				_scratch_local_rids.append(body.get_rid())
			if candidate == shooter or _is_ignored(candidate, ignored) \
			or bool(candidate.get_meta("combat_ignore", false)):
				continue
			var candidate_position: Vector3 = _snapshot_state.position(id)
			var circle := _cylinder_entry_distance(
				from, probe_end, candidate_position, _snapshot_state.combat_line_radius(id),
				_snapshot_state.combat_line_min_y(id), _snapshot_state.combat_line_max_y(id)
			)
			if is_inf(circle):
				continue
			if not CombatTargetScript.are_friendly(shooter, candidate):
				continue
			var entry := circle
			if _cylinder_contains(from, candidate_position, _snapshot_state.combat_line_radius(id), _snapshot_state.combat_line_min_y(id), _snapshot_state.combat_line_max_y(id)):
				if candidate.has_method("combat_line_entry_distance"):
					entry = float(candidate.call("combat_line_entry_distance", from, probe_end, candidate_position))
				else:
					entry = INF
			if entry < earliest_entry:
				earliest_entry = entry
		if not is_inf(earliest_entry):
			_prepare_excludes(_scratch_static_excludes, shooter, ignored, _scratch_local_rids)
			if earliest_entry < _first_obstruction_distance(world, from, probe_end, _scratch_static_excludes):
				return true
		if not _snapshot_has_carried:
			return false
		# A carried unit deliberately retains the old physics query. Cargo is
		# reparented below its carrier's VisualRoot, so its stored position is still
		# the pickup point while its collider follows the frame-dependent carrier.
		_prepare_excludes(_scratch_carried_excludes, shooter, ignored, _scratch_local_rids)
		return _carried_friendly_on_line(world, from, probe_end, shooter, _scratch_carried_excludes)
	return _friendly_on_line_without_match(world, from, probe_end, shooter, ignored, tree)


## Unit motion has completed before Match's later combat pass asks this
## predicate, so one immutable per-tick snapshot is valid for every turret
## query in that pass. This removes repeated group walks and metadata reads
## without caching the per-shot answer (whose endpoints can differ by muzzle).
static func _match_for_shooter(shooter_node: Node) -> Node:
	var shooter_id := shooter_node.get_instance_id()
	var cached: Node = _shooter_matches.get(shooter_id)
	if cached != null and is_instance_valid(cached) and cached.is_inside_tree() \
	and cached.get_tree() == shooter_node.get_tree():
		return cached
	var match_node := MatchLookupScript.match_node(shooter_node)
	if match_node != null:
		# A long match can create arbitrarily many shooter instance ids. This
		# cache is optional, so clear it at a fixed size instead of retaining
		# dead ids for the process lifetime.
		if _shooter_matches.size() >= 256:
			_shooter_matches.clear()
		_shooter_matches[shooter_id] = match_node
	return match_node


static func _ensure_match_snapshot(tree: SceneTree, match_node: Node) -> void:
	var tick := int(match_node.call("current_tick"))
	var tree_id := tree.get_instance_id()
	var match_id := match_node.get_instance_id()
	if _snapshot_tree_id != tree_id or _snapshot_match_id != match_id:
		_snapshot_tree_id = tree_id
		_snapshot_match_id = match_id
		_snapshot_index = match_node.call("entity_index")
		_snapshot_state = match_node.call("entity_state")
		_snapshot_tick = -1
		_snapshot_revision = -1
	var revision := int(_snapshot_state.combat_line_revision())
	if _snapshot_tick == tick and _snapshot_revision == revision:
		return
	_snapshot_tick = tick
	_snapshot_revision = revision
	_snapshot_grid.clear()
	_snapshot_has_carried = false
	_snapshot_build_ids.clear()
	for candidate_variant in tree.get_nodes_in_group(&"sim_units"):
		var candidate := candidate_variant as Object
		var body := candidate as CollisionObject3D
		var node := candidate as Node3D
		if candidate == null or not is_instance_valid(candidate) or body == null or node == null:
			continue
		var id: int = _snapshot_index.id_for(node)
		if id == 0 or not _snapshot_state.has_position(id):
			continue
		if _snapshot_state.has_combat_line_carried(id) and _snapshot_state.combat_line_carried(id):
			_snapshot_has_carried = true
			continue
		if not _snapshot_state.has_combat_line_bounds(id):
			continue
		_snapshot_build_ids.append(id)
	_snapshot_build_ids.sort()
	for id in _snapshot_build_ids:
		_snapshot_grid.insert(id, _snapshot_state.position(id), _snapshot_state.combat_line_radius(id))


static func _friendly_on_line_without_match(
		world: World3D, from: Vector3, probe_end: Vector3, shooter: Object, ignored: Array, tree: SceneTree
	) -> bool:
	var normal_unit_rids: Array[RID] = []
	var earliest_entry := INF
	for candidate_variant in tree.get_nodes_in_group(&"sim_units"):
		var candidate := candidate_variant as Object
		if candidate == null or not is_instance_valid(candidate) or candidate == shooter \
		or _is_ignored(candidate, ignored):
			continue
		if not candidate is CollisionObject3D:
			continue
		var carried := candidate.has_method("is_carried") and bool(candidate.call("is_carried"))
		if carried:
			continue
		normal_unit_rids.append((candidate as CollisionObject3D).get_rid())
		if bool(candidate.get_meta("combat_ignore", false)) \
		or not CombatTargetScript.are_friendly(shooter, candidate):
			continue
		if not candidate.has_method("combat_line_bounds") or not candidate.has_method("simulation_position"):
			continue
		var bounds: Dictionary = candidate.call("combat_line_bounds")
		if bounds.is_empty():
			continue
		var candidate_position: Vector3 = candidate.call("simulation_position")
		var entry := _cylinder_entry_distance(from, probe_end, candidate_position, float(bounds["radius"]), float(bounds["min_y"]), float(bounds["max_y"]))
		if _cylinder_contains(from, candidate_position, float(bounds["radius"]), float(bounds["min_y"]), float(bounds["max_y"])) and candidate.has_method("combat_line_entry_distance"):
			entry = float(candidate.call("combat_line_entry_distance", from, probe_end, candidate_position))
		if entry < earliest_entry:
			earliest_entry = entry
	var base_excludes: Array[RID] = []
	_prepare_excludes(base_excludes, shooter, ignored, normal_unit_rids)
	var obstruction_distance := _first_obstruction_distance(
		world, from, probe_end, base_excludes.duplicate()
	)
	if earliest_entry < obstruction_distance:
		return true
	return _carried_friendly_on_line(world, from, probe_end, shooter, base_excludes)


static func _is_ignored(candidate: Object, ignored: Array) -> bool:
	for ignored_candidate: Variant in ignored:
		if candidate == ignored_candidate:
			return true
	return false


static func _prepare_excludes(
		excludes: Array[RID], shooter: Object, ignored: Array, nearby_normal_rids: Array[RID]
	) -> void:
	excludes.clear()
	for ignored_candidate: Variant in ignored:
		CombatTargetScript.append_collision_rids(ignored_candidate as Object, excludes)
	CombatTargetScript.append_collision_rids(shooter, excludes)
	excludes.append_array(nearby_normal_rids)


static func _friendly_on_line_legacy(
		world: World3D,
		from: Vector3,
		probe_end: Vector3,
		shooter: Object,
		ignored: Array,
		extra_excludes: Array[RID] = []
	) -> bool:
	var excludes: Array[RID] = []
	for candidate: Variant in ignored:
		excludes.append_array(CombatTargetScript.collision_rids(candidate as Object))
	excludes.append_array(CombatTargetScript.collision_rids(shooter))
	excludes.append_array(extra_excludes)
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


## The static scan is intentionally separate from is_clear(): this answer is
## only the limiting entry distance for the friendly hull test. Non-local unit
## bodies are deliberately pierced rather than globally excluded; the 4096
## query limit is an explicit safety bound for stale physics snapshots.
static func _first_obstruction_distance(
		world: World3D, from: Vector3, probe_end: Vector3, excludes: Array[RID]
	) -> float:
	for index in MAX_FRIENDLY_LINE_PIERCES:
		var query := PhysicsRayQueryParameters3D.create(
			from, probe_end, BLOCKER_COLLISION_MASK, excludes
		)
		query.collide_with_areas = false
		query.collide_with_bodies = true
		var hit := world.direct_space_state.intersect_ray(query)
		if hit.is_empty():
			return INF
		var rid: RID = hit.get("rid", RID())
		if not rid.is_valid():
			return INF
		if _obstructs(hit.get("collider") as Object):
			return from.distance_to(Vector3(hit.get("position", from)))
		excludes.append(rid)
	push_error("CombatLineOfFire: friendly-line static ray exhausted 4096 pierces")
	return INF


static func _carried_friendly_on_line(
		world: World3D,
		from: Vector3,
		probe_end: Vector3,
		shooter: Object,
		excludes: Array[RID]
	) -> bool:
	for index in MAX_FRIENDLY_LINE_PIERCES:
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
			if entity != null and entity.has_method("combat_hull"):
				return false
			if entity != null and entity.has_method("is_carried") \
			and bool(entity.call("is_carried")) and entity != shooter \
			and CombatTargetScript.are_friendly(shooter, entity):
				return true
		excludes.append(rid)
	push_error("CombatLineOfFire: friendly-line carried ray exhausted 4096 pierces")
	return false


## First 3D entry into the finite yaw-invariant authored envelope.  The
## outside-start answer is deliberately the conservative cylinder; callers
## resolve only starts already inside it through the authored convex planes.
static func _cylinder_entry_distance(
		from: Vector3, to: Vector3, center: Vector3, radius: float, min_y: float, max_y: float
	) -> float:
	var horizontal_from := Vector2(from.x - center.x, from.z - center.z)
	var horizontal_delta := Vector2(to.x - from.x, to.z - from.z)
	var interval := Vector2(0.0, 1.0)
	var a := horizontal_delta.length_squared()
	if a <= 0.00000001:
		if horizontal_from.length_squared() > radius * radius:
			return INF
	else:
		var b := 2.0 * horizontal_from.dot(horizontal_delta)
		var c := horizontal_from.length_squared() - radius * radius
		var discriminant := b * b - 4.0 * a * c
		if discriminant < 0.0:
			return INF
		var root := sqrt(discriminant)
		interval.x = maxf(interval.x, (-b - root) / (2.0 * a))
		interval.y = minf(interval.y, (-b + root) / (2.0 * a))
	var y_delta := to.y - from.y
	if absf(y_delta) <= 0.00000001:
		if from.y < center.y + min_y or from.y > center.y + max_y:
			return INF
	else:
		var y0 := (center.y + min_y - from.y) / y_delta
		var y1 := (center.y + max_y - from.y) / y_delta
		interval.x = maxf(interval.x, minf(y0, y1))
		interval.y = minf(interval.y, maxf(y0, y1))
	if interval.x > interval.y or interval.y < 0.0 or interval.x > 1.0:
		return INF
	return from.distance_to(to) * maxf(interval.x, 0.0)


static func _cylinder_contains(
		point: Vector3, center: Vector3, radius: float, min_y: float, max_y: float
	) -> bool:
	var horizontal := Vector2(point.x - center.x, point.z - center.z)
	return horizontal.length_squared() <= radius * radius and point.y >= center.y + min_y \
	and point.y <= center.y + max_y


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
