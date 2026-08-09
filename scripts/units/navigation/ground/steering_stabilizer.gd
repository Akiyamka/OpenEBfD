class_name SteeringStabilizer
extends RefCounted

const EntityQueryScript := preload("res://scripts/world/entity_query.gd")
const MapNavigationGridScript := preload("res://scripts/world/map/map_navigation_grid.gd")
## Hard/soft geometry shared by every ground avoidance backend: terrain swept-
## disc checks and pressure field, friendly elastic separation, enemy swept-disc
## checks, and the non-holonomic chassis rate limiter (`stabilize_velocity`).
## Extracted verbatim from `unit_local_avoidance.gd` so the candidate-sampling
## and ORCA backends can share one geometry implementation.

const CONTACT_BUFFER := 0.05
const SEPARATION_STIFFNESS := 2.5
const SEPARATION_MAX_SPEED_FACTOR := 0.35
const FRIEND_COMFORT_RADIUS_FACTOR := 0.35
const TERRAIN_SOFT_MARGIN_CELLS := 0.8
const TERRAIN_PRESSURE_WEIGHT := 0.65
const STEERING_TURN_RATE_SHARE := 0.85
const STEERING_CLOSE_TARGET_MAX_BEARING := 0.65
const STEERING_DRIVEN_ARC_MAX_BEARING := 1.7
const STEERING_CLOSE_TARGET_TURN_RADIUS_FACTOR := 1.25
const RULE_MOVEMENT_UPDATES_PER_SECOND := 20.0
const OBSTACLE_BUCKET_CELLS := 8

var runtime_map = null
var _obstacle_profiles: Dictionary = {}


func setup(source_runtime_map) -> void:
	runtime_map = source_runtime_map
	_obstacle_profiles.clear()


func prewarm(pass_mask: int, terrain_mask: int) -> void:
	_obstacle_profile(pass_mask, terrain_mask)


## A non-omnidirectional Unit otherwise receives a new, instantly rotated
## velocity every navigation tick, while Unit.navigation_step must stop until
## its chassis catches that heading. Limit the requested course to slightly
## less than the same rules turn step, so a corner becomes one driven arc.
## If that intermediate arc would cross a hard boundary, retain the already
## safe target: the unit then turns in place instead of cutting the corner.
func stabilize_velocity(
		agent: Dictionary,
		proposed: Vector3,
		delta: float,
		nearby: Array,
		resolved: Dictionary
	) -> Vector3:
	if proposed.is_zero_approx() or delta <= 0.0:
		agent["steering_turn_in_place"] = false
		return proposed
	var unit: Node3D = agent["unit"]
	if not unit.has_method("facing_direction"):
		return proposed
	var omnidirectional = unit.get("can_move_any_direction")
	if omnidirectional != null and bool(omnidirectional):
		return proposed
	var turn_rate_value = unit.get("turn_rate")
	if turn_rate_value == null or float(turn_rate_value) <= 0.0:
		return proposed
	var facing: Vector3 = unit.call("facing_direction")
	facing.y = 0.0
	if facing.is_zero_approx():
		return proposed
	facing = facing.normalized()
	var target_direction := proposed.normalized()
	var difference := facing.signed_angle_to(target_direction, Vector3.UP)
	var maximum_step := float(turn_rate_value) * RULE_MOVEMENT_UPDATES_PER_SECOND \
		* delta * STEERING_TURN_RATE_SHARE
	if bool(agent.get("steering_turn_in_place", false)):
		if absf(difference) <= maximum_step:
			agent["steering_turn_in_place"] = false
		else:
			return proposed
	if absf(difference) <= maximum_step:
		return proposed
	# A large bearing only creates an orbit when the pursuit point is inside the
	# chassis' turn circle. Far corners should start a driven arc; stopping there
	# turns every smoothly moving look-ahead target into visible stop-and-go.
	# A genuinely reverse bearing still turns in place instead of making a wide
	# U-turn away from the order.
	var angular_speed := float(turn_rate_value) * RULE_MOVEMENT_UPDATES_PER_SECOND
	var turn_radius := proposed.length() / maxf(angular_speed, 0.001)
	var steering_target: Vector3 = agent.get("steering_target", unit.global_position)
	var target_offset := steering_target - unit.global_position
	target_offset.y = 0.0
	var close_target := target_offset.length() <= maxf(
		float(agent["radius"]), turn_radius * STEERING_CLOSE_TARGET_TURN_RADIUS_FACTOR
	)
	if absf(difference) > STEERING_DRIVEN_ARC_MAX_BEARING \
	or (close_target and absf(difference) > STEERING_CLOSE_TARGET_MAX_BEARING):
		agent["steering_turn_in_place"] = true
		return proposed
	var reachable_direction := facing.rotated(
		Vector3.UP, clampf(difference, -maximum_step, maximum_step)
	).normalized()
	var reachable := reachable_direction * proposed.length()
	var displacement := reachable * delta
	var hard_fraction := terrain_sweep_fraction(agent, displacement)
	hard_fraction = minf(
		hard_fraction,
		enemy_sweep_fraction(agent, displacement, nearby, resolved)
	)
	if hard_fraction <= 0.001:
		agent["steering_turn_in_place"] = true
		return proposed
	return reachable * hard_fraction


## Hard terrain fraction for a swept unit disc against nearby round cells.
## Starting in a truly forbidden cell keeps the production/refinery escape
## exception: the route may move outward until its centre reaches open ground.
func terrain_sweep_fraction(agent: Dictionary, displacement: Vector3) -> float:
	return _terrain_sweep_fraction_from(
		agent, displacement, terrain_context(agent, displacement.length())
	)


func _terrain_sweep_fraction_from(
		agent: Dictionary,
		displacement: Vector3,
		terrain: Dictionary
	) -> float:
	if runtime_map == null or runtime_map.grid == null:
		return 0.0
	if bool(terrain.get("escape", false)):
		return 1.0
	var unit: Node3D = agent["unit"]
	var start := unit.global_position
	var combined := float(terrain["hard_radius"])
	var fraction := 1.0
	for value in terrain["obstacles"]:
		fraction = minf(
			fraction,
			sweep_fraction(start, displacement, value as Vector3, combined)
		)
	return fraction


func motion_is_passable(agent: Dictionary, displacement: Vector3) -> bool:
	return terrain_sweep_fraction(agent, displacement) >= 0.999


## Smooth repulsion begins before hard contact. It biases candidate generation
## but never authorizes motion through the hard swept-disc limit above.
func terrain_pressure(agent: Dictionary) -> Vector3:
	return _terrain_pressure_from(
		agent, terrain_context(agent, 0.0)
	)


func _terrain_pressure_from(agent: Dictionary, terrain: Dictionary) -> Vector3:
	if runtime_map == null or runtime_map.grid == null:
		return Vector3.ZERO
	if bool(terrain.get("escape", false)):
		return Vector3.ZERO
	var unit: Node3D = agent["unit"]
	var position := unit.global_position
	var soft_margin := float(terrain["soft_margin"])
	var field_radius := float(terrain["field_radius"])
	var pressure := Vector3.ZERO
	for value in terrain["obstacles"]:
		var away := position - (value as Vector3)
		away.y = 0.0
		var distance := away.length()
		if distance >= field_radius:
			continue
		if distance <= 0.001:
			away = Vector3.RIGHT
			distance = 0.001
		var weight := clampf((field_radius - distance) / soft_margin, 0.0, 1.0)
		pressure += away / distance * weight * weight
	return pressure.limit_length(1.0)


func _apply_pressure(desired: Vector3, pressure: Vector3) -> Vector3:
	if pressure.is_zero_approx():
		return desired
	return (desired + pressure * desired.length() * TERRAIN_PRESSURE_WEIGHT) \
		.limit_length(desired.length())


## Nearby solid-cell obstacle discs (inscribed circles) around `agent`, plus the
## derived hard/soft radii used by both the swept-disc fraction and the pressure
## field. Shared by the candidate-sampling and ORCA avoidance backends.
func terrain_context(agent: Dictionary, movement_reach: float) -> Dictionary:
	var unit: Node3D = agent["unit"]
	var position := unit.global_position
	var origin: Vector2i = runtime_map.grid.world_to_grid(position)
	var cell_size: Vector2 = runtime_map.grid.cell_size()
	var obstacle_radius := maxf(minf(cell_size.x, cell_size.y) * 0.5, 0.001)
	var soft_margin := maxf(
		minf(cell_size.x, cell_size.y) * TERRAIN_SOFT_MARGIN_CELLS, 0.001
	)
	# Unit/unit spacing uses the capsule width. Static terrain uses the full
	# rotation envelope so the nose and tail of a long chassis remain clear while
	# it changes heading around a building corner.
	var hard_radius := float(agent.get(
		"terrain_radius", agent.get("rotation_radius", agent["radius"])
	)) + obstacle_radius
	var field_radius := hard_radius + soft_margin
	var scan_world := maxf(
		field_radius,
		hard_radius + movement_reach + CONTACT_BUFFER
	)
	var scan_x := ceili(scan_world / maxf(cell_size.x, 0.001)) + 1
	var scan_y := ceili(scan_world / maxf(cell_size.y, 0.001)) + 1
	var obstacles: Array[Vector3] = []
	var profile := _obstacle_profile(int(agent["pass_mask"]), int(agent["terrain_mask"]))
	var buckets: Dictionary = profile["buckets"]
	var first := origin - Vector2i(scan_x, scan_y)
	var last := origin + Vector2i(scan_x, scan_y)
	var first_bucket := Vector2i(
		floori(float(first.x) / float(OBSTACLE_BUCKET_CELLS)),
		floori(float(first.y) / float(OBSTACLE_BUCKET_CELLS))
	)
	var last_bucket := Vector2i(
		floori(float(last.x) / float(OBSTACLE_BUCKET_CELLS)),
		floori(float(last.y) / float(OBSTACLE_BUCKET_CELLS))
	)
	for bucket_y in range(first_bucket.y, last_bucket.y + 1):
		for bucket_x in range(first_bucket.x, last_bucket.x + 1):
			for cell_variant in buckets.get(Vector2i(bucket_x, bucket_y), []):
				var cell: Vector2i = cell_variant
				if cell.x < first.x or cell.x > last.x \
				or cell.y < first.y or cell.y > last.y:
					continue
				if not _cell_is_solid(agent, cell):
					continue
				obstacles.append(_obstacle_world(cell, position.y))
	# The cached profile contains only in-bounds cells. Add the small outside
	# strip only for units whose continuous field actually reaches a map edge.
	if first.x < 0 or first.y < 0 \
	or last.x >= MapNavigationGridScript.NAV_SIZE or last.y >= MapNavigationGridScript.NAV_SIZE:
		for y in range(first.y, last.y + 1):
			for x in range(first.x, last.x + 1):
				var cell := Vector2i(x, y)
				if runtime_map.grid.in_bounds(cell):
					continue
				obstacles.append(_obstacle_world(cell, position.y))
	return {
		"escape": not _agent_cell_passable(agent, origin, 0, 0),
		"obstacles": obstacles,
		"hard_radius": hard_radius,
		"soft_margin": soft_margin,
		"field_radius": field_radius,
	}


func _obstacle_profile(pass_mask: int, terrain_mask: int) -> Dictionary:
	var key := "%d:%d" % [pass_mask, terrain_mask]
	var profile: Dictionary = _obstacle_profiles.get(key, {})
	if not profile.is_empty() and int(profile["revision"]) == runtime_map.revision:
		return profile
	var buckets := {}
	var grid = runtime_map.grid
	var blocked: PackedByteArray = runtime_map.blocked_cells()
	for index in MapNavigationGridScript.NAV_SIZE * MapNavigationGridScript.NAV_SIZE:
		if (grid.pass_mask[index] & pass_mask) != 0 and blocked[index] == 0 \
		and (terrain_mask == 0 or (terrain_mask & (1 << grid.terrain_type[index])) != 0):
			continue
		var cell := Vector2i(
			index % MapNavigationGridScript.NAV_SIZE,
			index / MapNavigationGridScript.NAV_SIZE
		)
		var bucket := Vector2i(
			cell.x / OBSTACLE_BUCKET_CELLS,
			cell.y / OBSTACLE_BUCKET_CELLS
		)
		if not buckets.has(bucket):
			buckets[bucket] = [] as Array[Vector2i]
		(buckets[bucket] as Array).append(cell)
	profile = {"revision": runtime_map.revision, "buckets": buckets}
	_obstacle_profiles[key] = profile
	return profile


func _obstacle_world(cell: Vector2i, height: float) -> Vector3:
	var result: Vector3 = runtime_map.grid.grid_to_world(cell)
	result.y = height
	return result


func enemy_sweep_fraction(
		agent: Dictionary,
		displacement: Vector3,
		nearby: Array,
		resolved: Dictionary
	) -> float:
	var unit: Node3D = agent["unit"]
	var fraction := 1.0
	for other in nearby:
		var other_unit: Node3D = other["unit"]
		if other_unit == unit or not _are_enemies(unit, other_unit):
			continue
		var other_position: Vector3 = resolved.get(
			other_unit.get_instance_id(), other_unit.global_position
		)
		fraction = minf(fraction, sweep_fraction(
			unit.global_position,
			displacement,
			other_position,
			float(agent["radius"]) + float(other["radius"])
		))
	return fraction


## Swept-disc clear fraction against every other nearby agent (friend or foe
## alike), unlike `enemy_sweep_fraction` above which only checks enemies.
## `radius_factor` shrinks the combined contact radius used for the check: a
## caller relying on the bounded elastic overlap `separation_velocity` allows
## between friendlies (rather than demanding fully round, non-overlapping
## bodies) passes a factor below 1.0 so genuine contact still drives the
## fraction toward zero without also rejecting that ordinary close-in squeeze.
func unit_sweep_fraction(
		agent: Dictionary,
		displacement: Vector3,
		nearby: Array,
		radius_factor := 1.0
	) -> float:
	var unit: Node3D = agent["unit"]
	var fraction := 1.0
	for other in nearby:
		var other_unit: Node3D = other["unit"]
		if other_unit == unit:
			continue
		fraction = minf(fraction, sweep_fraction(
			unit.global_position,
			displacement,
			other_unit.global_position,
			(float(agent["radius"]) + float(other["radius"])) * radius_factor
		))
	return fraction


## Elastic penetration field. Friendly squeeze may overlap temporarily; this
## bounded force continuously restores the round non-overlapping state.
func separation_velocity(agent: Dictionary, nearby: Array) -> Vector3:
	var unit: Node3D = agent["unit"]
	var push := Vector3.ZERO
	for other in nearby:
		if other["unit"] == unit:
			continue
		var other_unit: Node3D = other["unit"]
		var away := unit.global_position - other_unit.global_position
		away.y = 0.0
		var combined := float(agent["radius"]) + float(other["radius"])
		var distance := away.length()
		if distance >= combined:
			continue
		if distance <= 0.001:
			push += (Vector3.RIGHT if int(agent["id"]) < int(other["id"]) else Vector3.LEFT) \
				* combined
		else:
			push += away / distance * (combined - distance)
	if push.is_zero_approx():
		return Vector3.ZERO
	return (push * SEPARATION_STIFFNESS).limit_length(
		_unit_speed(unit) * SEPARATION_MAX_SPEED_FACTOR
	)


static func sweep_fraction(
		start: Vector3,
		displacement: Vector3,
		obstacle: Vector3,
		combined_radius: float
	) -> float:
	var relative := start - obstacle
	relative.y = 0.0
	var motion := displacement
	motion.y = 0.0
	var contact := combined_radius + CONTACT_BUFFER
	if relative.length_squared() <= contact * contact:
		return 1.0 if relative.dot(motion) >= 0.0 else 0.0
	var c := relative.length_squared() - combined_radius * combined_radius
	var a := motion.length_squared()
	if a <= 0.000001:
		return 0.0
	var b := 2.0 * relative.dot(motion)
	var discriminant := b * b - 4.0 * a * c
	if discriminant < 0.0:
		return 1.0
	var hit := (-b - sqrt(discriminant)) / (2.0 * a)
	return clampf(hit - 0.01, 0.0, 1.0) if hit >= 0.0 and hit <= 1.0 else 1.0


func _cell_is_solid(agent: Dictionary, cell: Vector2i) -> bool:
	var grid = runtime_map.grid
	if not grid.in_bounds(cell):
		return true
	var pass_mask := int(agent["pass_mask"])
	if not grid.is_passable(cell, pass_mask):
		return true
	var terrain_mask := int(agent["terrain_mask"])
	if terrain_mask != 0 and (terrain_mask & (1 << grid.terrain_at(cell))) == 0:
		return true
	return runtime_map.is_blocked(cell) and not (agent.get("allowed_cells", {}) as Dictionary).has(cell)


func _agent_cell_passable(
		agent: Dictionary,
		cell: Vector2i,
		clearance_cells := -1,
		allowed_terrain_mask := -1
	) -> bool:
	var clearance := int(agent["clearance"]) if clearance_cells < 0 else clearance_cells
	var terrain_mask := int(agent["terrain_mask"]) \
		if allowed_terrain_mask < 0 else allowed_terrain_mask
	var pass_mask := int(agent["pass_mask"])
	if runtime_map.is_passable(cell, pass_mask, clearance, terrain_mask):
		return true
	var allowed: Dictionary = agent.get("allowed_cells", {})
	if allowed.is_empty():
		return false
	for y in range(-clearance, clearance + 1):
		for x in range(-clearance, clearance + 1):
			var sample := cell + Vector2i(x, y)
			if not runtime_map.grid.is_passable(sample, pass_mask):
				return false
			if terrain_mask != 0 \
			and (terrain_mask & (1 << runtime_map.grid.terrain_at(sample))) == 0:
				return false
			if runtime_map.is_blocked(sample) and not allowed.has(sample):
				return false
	return true


static func _are_enemies(a: Node3D, b: Node3D) -> bool:
	if a.has_method("is_enemy_of"):
		var owner_id := EntityQueryScript.owner_id_of(b)
		return owner_id >= 0 and bool(a.call("is_enemy_of", owner_id))
	return false


static func _unit_speed(unit: Node3D) -> float:
	if unit.has_method("navigation_move_speed"):
		return maxf(float(unit.call("navigation_move_speed")), 0.0)
	var value = unit.get("move_speed")
	return maxf(float(value), 0.0) if value != null else 0.0
