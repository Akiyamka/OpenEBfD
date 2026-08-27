class_name GroundPathFollower
extends RefCounted

const NavConstantsScript := preload("res://scripts/units/navigation/shared/nav_constants.gd")
const RuleTicksScript := preload("res://scripts/rules/rule_ticks.gd")
const MatchClockScript := preload("res://scripts/sim/match_clock.gd")
## Runtime pursuit of a compact A* path: look-ahead steering target, monotonic
## waypoint advancement, cross-route lane offsetting, and the swept-disc
## visibility tests (chord/line-of-sight, per-cell passable/stoppable) that
## everything else in ground navigation treats as the real movement
## constraint. Also releases a harvester's temporary refinery-apron access
## once the follower has delivered it outside those cells.

var _facade: Node
var _runtime_map
var _avoidance
var _registry
var _slot_allocator_ref: WeakRef
var _ground_navigation_ref: WeakRef

## Continuous swept-disc visibility gathers nearby obstacle cells in a square
## around the unit. That is exact and cheap for local corner look-ahead, but a
## long final chord next to a large cliff makes the square grow as distance².
## Beyond this many cells use the linear A* grid corridor check; actual motion
## remains guarded by the continuous short-step terrain sweep in avoidance.
const CONTINUOUS_CHORD_MAX_CELLS := 8.0
const LANE_SIDE_BOTH_OPEN := 0
const LANE_SIDE_POSITIVE := 1
const LANE_SIDE_NEGATIVE := -1
const LANE_SIDE_NEITHER_OPEN := 2


func setup(facade: Node, runtime_map, avoidance, registry, slot_allocator, ground_navigation) -> void:
	_facade = facade
	_runtime_map = runtime_map
	_avoidance = avoidance
	_registry = registry
	_slot_allocator_ref = weakref(slot_allocator)
	_ground_navigation_ref = weakref(ground_navigation)


## Follow a point ahead on the compact path instead of aiming at a corner until
## its centre is reached. The look-ahead combines body radius with minimum turn
## radius, so a large slow-turning unit begins one continuous bend earlier.
## A chord across the corner is accepted only while the agent's real swept disc
## remains clear; otherwise a short binary search keeps the furthest safe point.
func path_steering_target(
		agent: Dictionary,
		path: Array,
		path_index: int,
		position: Vector3,
		speed: float
	) -> Vector3:
	var current: Vector3 = path[path_index]
	current.y = position.y
	if path_index >= path.size() - 1:
		var destination: Vector3 = agent["destination"]
		destination.y = position.y
		if path_chord_is_clear(agent, position, destination):
			return destination
		if not path_chord_is_clear(agent, position, current):
			return current
		# A larger single-tick displacement (e.g. ORCA squeezing at up to full
		# cruise speed through a choke point) can land right on the boundary
		# where the destination chord clears on one tick and not the next.
		# Snapping straight back to `current` on the losing tick reverses the
		# commanded direction outright — bisect toward the furthest safe point
		# instead, the same way the look-ahead branch below already does, so
		# the target degrades smoothly rather than flipping.
		var safe := current
		var blocked := destination
		for _iteration in 8:
			var probe := safe.lerp(blocked, 0.5)
			if path_chord_is_clear(agent, position, probe):
				safe = probe
			else:
				blocked = probe
		return safe
	var look_ahead := path_look_ahead_distance(agent, speed)
	var first_leg := current - position
	first_leg.y = 0.0
	if first_leg.length() >= look_ahead:
		return current
	var remaining := look_ahead - first_leg.length()
	var cursor := current
	var candidate := current
	for index in range(path_index + 1, path.size()):
		var endpoint: Vector3 = path[index]
		endpoint.y = position.y
		var segment := endpoint - cursor
		segment.y = 0.0
		var length := segment.length()
		if length >= remaining and length > 0.001:
			candidate = cursor + segment / length * remaining
			break
		candidate = endpoint
		remaining -= length
		cursor = endpoint
		if remaining <= 0.001:
			break
	if path_chord_is_clear(agent, position, candidate):
		return candidate
	if not path_chord_is_clear(agent, position, current):
		return current
	var safe := current
	var blocked := candidate
	for _iteration in 8:
		var probe := safe.lerp(blocked, 0.5)
		if path_chord_is_clear(agent, position, probe):
			safe = probe
		else:
			blocked = probe
	return safe


## A compact-path waypoint is a cross-section of the route, not a pin that the
## unit centre must touch. Collision steering can displace a large body past a
## corner without ever entering the old radius-based capture circle. Once it is
## on the outgoing side and still near that segment, progress is monotonic and
## the follower must not turn back toward the missed cell centre.
func advanced_path_index(
		agent: Dictionary,
		path: Array,
		path_index: int,
		position: Vector3,
		speed := 0.0
	) -> int:
	var result := path_index
	var cell_size: Vector2 = _runtime_map.grid.cell_size()
	var cell_width := maxf(minf(cell_size.x, cell_size.y), 0.001)
	# A step-based avoidance backend (ORCA) can drive a full-speed tick's
	# worth of displacement straight through a waypoint's old fixed capture
	# radius without ever landing inside it — position samples land just
	# short one tick and just past the next, so the follower keeps aiming
	# at the same never-quite-captured point from alternating sides, which
	# reverses the commanded heading every tick. Covering at least one tick's
	# travel keeps a single overshooting step inside the capture disc.
	var capture := maxf(maxf(0.35, float(agent["radius"]) * 0.4), speed * MatchClockScript.SECONDS_PER_TICK)
	var base_corridor := maxf(float(agent["radius"]) * 2.0, cell_width * 1.5)
	while result < path.size() - 1:
		var waypoint: Vector3 = path[result]
		var next: Vector3 = path[result + 1]
		waypoint.y = position.y
		next.y = position.y
		var outgoing := next - waypoint
		outgoing.y = 0.0
		var length := outgoing.length()
		if length <= 0.001:
			result += 1
			continue
		outgoing /= length
		var relative := position - waypoint
		relative.y = 0.0
		var along := relative.dot(outgoing)
		var lateral := (relative - outgoing * clampf(along, 0.0, length)).length()
		# Group lanes deliberately carry outer units past the waypoint away
		# from the A* centre line. The waypoint gate must cover that complete
		# cross-section; otherwise an outer unit crosses on its assigned lane,
		# fails the centre-only test, and curves back to touch the old point.
		var lane_corridor := base_corridor + absf(_effective_lane_offset(agent, result))
		if relative.length() <= capture or (along > 0.0 and lateral <= lane_corridor):
			result += 1
			continue
		break
	return result


## Preserve the group's cross-route order while several A* paths share a
## corner. In open space lanes remain centred around the path. If one side of a
## waypoint is terrain, the whole set is rebased onto the open side: the
## innermost unit follows the A* centre line and its neighbours remain outside
## it instead of being squeezed into the obstacle.
func path_lane_target(
		agent: Dictionary,
		path: Array,
		path_index: int,
		position: Vector3,
		base_target: Vector3,
		speed: float
	) -> Vector3:
	if path_index >= path.size() - 1:
		return base_target
	var lane_min := float(agent.get("route_lane_min", 0.0))
	var lane_max := float(agent.get("route_lane_max", 0.0))
	var lane_span := lane_max - lane_min
	if lane_span <= 0.05:
		return base_target
	var forward := base_target - position
	forward.y = 0.0
	if forward.length_squared() <= 0.0001:
		return base_target
	forward = forward.normalized()
	var lateral := forward.cross(Vector3.UP).normalized()
	# Which side is open is a geometric fact about this waypoint's corner, not
	# something to re-judge from the agent's exact fractional position every
	# tick: a corner tight enough that only one side's probe clears can flip
	# which side reads "open" for a sub-metre position change, re-aiming the
	# whole lane rebase to the opposite side and back — a stable two-point
	# limit cycle (a full-speed step lands close enough to the previous tick's
	# position to flip the verdict right back), not just visual jitter. Decide
	# once per segment, cached by `path_index`, and hold it until the agent
	# actually advances past this waypoint.
	var side := int(agent.get("_lane_rebase_side", LANE_SIDE_BOTH_OPEN))
	if int(agent.get("_lane_rebase_index", -1)) != path_index:
		var probe_distance := maxf(lane_span, float(agent["radius"]) * 0.75)
		var positive := base_target + lateral * probe_distance
		var negative := base_target - lateral * probe_distance
		var positive_open := has_clear_line(base_target, positive, agent)
		var negative_open := has_clear_line(base_target, negative, agent)
		if positive_open and not negative_open:
			side = LANE_SIDE_POSITIVE
		elif negative_open and not positive_open:
			side = LANE_SIDE_NEGATIVE
		elif not positive_open and not negative_open:
			side = LANE_SIDE_NEITHER_OPEN
		else:
			side = LANE_SIDE_BOTH_OPEN
		agent["_lane_rebase_side"] = side
		agent["_lane_rebase_index"] = path_index
	var lane_offset := _effective_lane_offset(agent, path_index)
	if side == LANE_SIDE_NEITHER_OPEN:
		return base_target
	# Merge back into the unit's exact destination instead of carrying a lane
	# offset into the final parking block.
	var destination: Vector3 = agent["destination"]
	destination.y = position.y
	var fade_distance := maxf(path_look_ahead_distance(agent, speed) * 2.0, 0.001)
	lane_offset *= clampf(base_target.distance_to(destination) / fade_distance, 0.0, 1.0)
	if absf(lane_offset) <= 0.01:
		return base_target
	var candidate := base_target + lateral * lane_offset
	if path_chord_is_clear(agent, position, candidate):
		return candidate
	# The route can narrow after a broad approach. Retain as much lateral order
	# as the real swept body can reach rather than snapping every unit to centre.
	var safe := base_target
	var blocked := candidate
	for _iteration in 8:
		var probe := safe.lerp(blocked, 0.5)
		if path_chord_is_clear(agent, position, probe):
			safe = probe
		else:
			blocked = probe
	return safe


func _effective_lane_offset(agent: Dictionary, path_index: int) -> float:
	var lane_offset := float(agent.get("route_lane_offset", 0.0))
	if int(agent.get("_lane_rebase_index", -1)) != path_index:
		return lane_offset
	var side := int(agent.get("_lane_rebase_side", LANE_SIDE_BOTH_OPEN))
	if side == LANE_SIDE_POSITIVE:
		lane_offset -= float(agent.get("route_lane_min", 0.0))
	elif side == LANE_SIDE_NEGATIVE:
		lane_offset -= float(agent.get("route_lane_max", 0.0))
	elif side == LANE_SIDE_NEITHER_OPEN:
		return 0.0
	return lane_offset


func path_chord_is_clear(agent: Dictionary, from: Vector3, to: Vector3) -> bool:
	# Square visibility belongs to global A*: it is conservative enough to find
	# a route for every footprint, but releases a rounded corner one whole cell
	# at a time. Runtime pursuit already starts at the real unit position, so its
	# swept disc against the rounded obstacle field is both the exact movement
	# constraint and a continuous visibility test. Keeping _has_clear_line here
	# made the yellow look-ahead target advance in visible steps.
	# A unit spawned inside production/refinery body cells temporarily receives
	# an escape sweep which accepts outward motion. That exception is safe for a
	# short movement tick but must not declare an arbitrary long look-ahead chord
	# clear through the building it is leaving.
	if not agent_cell_passable(agent, _runtime_map.grid.world_to_grid(from), 0):
		return has_clear_line(from, to, agent)
	var cell_size: Vector2 = _runtime_map.grid.cell_size()
	var cell_width := maxf(minf(cell_size.x, cell_size.y), 0.001)
	var chord := to - from
	chord.y = 0.0
	if chord.length() > cell_width * CONTINUOUS_CHORD_MAX_CELLS:
		return has_clear_line(from, to, agent)
	return _avoidance.terrain_sweep_fraction(agent, to - from) >= 0.999


func path_look_ahead_distance(agent: Dictionary, speed: float) -> float:
	var cell_size: Vector2 = _runtime_map.grid.cell_size()
	var cell_width := maxf(minf(cell_size.x, cell_size.y), 0.001)
	var radius_distance := float(agent.get("rotation_radius", agent["radius"])) * 1.5
	var unit: Node3D = agent["unit"]
	var turn_rate_value = unit.get("turn_rate")
	var turn_distance := cell_width
	var omnidirectional_value = unit.get("can_move_any_direction")
	if (omnidirectional_value == null or not bool(omnidirectional_value)) \
	and turn_rate_value != null and float(turn_rate_value) > 0.0:
		# Rules.txt TurnRate is radians per rules movement update, and the
		# original engine ran twenty of those per second. Deliberately not
		# MatchClock.TICKS_PER_SECOND: that is how often this simulation
		# decides things, which has nothing to do with the cadence the source
		# data was authored against. The two used to be the same number, back
		# when this line read the navigation system's own 20 Hz rate -- which
		# is exactly how it came to read the wrong one. See slice A1a.
		var angular_speed := float(turn_rate_value) * RuleTicksScript.RULE_MOVEMENT_UPDATES_PER_SECOND
		turn_distance = clampf(speed / angular_speed * 2.5, cell_width, cell_width * 6.0)
	return maxf(radius_distance, turn_distance)


func release_departure_access_if_clear(agent: Dictionary) -> void:
	if not bool(agent.get("departure_access", false)):
		return
	var allowed: Dictionary = agent["allowed_cells"]
	agent["allowed_cells"] = {}
	_registry.set_agent_rotation_envelope(agent, true)
	var unit: Node3D = agent["unit"]
	# simulation_position(), not global_position, since slice R4: whether the
	# harvester's body has cleared the refinery apron is a tick decision, and
	# the route it plans on clearing it starts from the same number the rest of
	# the tick uses. Read once for both -- the accessor resolves the owning
	# Match by walking this node's ancestors (MatchLookup._live_match) where a
	# field read was free, and nothing between the two moves the unit
	# (set_agent_rotation_envelope only rewrites agent keys). `unit` stays a
	# bare Node3D, so the call is duck-typed and a test double has to answer it.
	var unit_position: Vector3 = unit.simulation_position()
	var slot_allocator = _slot_allocator_ref.get_ref()
	var anchor: Vector2i = slot_allocator.parking_anchor(
		unit_position, int(agent["footprint"])
	)
	if not slot_allocator.block_stoppable(anchor, int(agent["footprint"]), agent):
		_registry.set_agent_rotation_envelope(agent, false)
		agent["allowed_cells"] = allowed
		return
	agent["departure_access"] = false
	_ground_navigation_ref.get_ref().route_agent(
		agent, unit_position, agent["destination"]
	)


func has_clear_line(from: Vector3, to: Vector3, agent: Dictionary) -> bool:
	var start: Vector2i = _runtime_map.grid.world_to_grid(from)
	var finish: Vector2i = _runtime_map.grid.world_to_grid(to)
	var delta: Vector2i = finish - start
	var steps := maxi(absi(delta.x), absi(delta.y))
	if steps == 0:
		return true
	var previous: Vector2i = start
	for index in range(1, steps + 1):
		var weight := float(index) / float(steps)
		var cell := Vector2i(
			roundi(lerpf(float(start.x), float(finish.x), weight)),
			roundi(lerpf(float(start.y), float(finish.y), weight))
		)
		if not agent_cell_passable(agent, cell):
			return false
		var step: Vector2i = cell - previous
		if step.x != 0 and step.y != 0:
			if not agent_cell_passable(agent, previous + Vector2i(step.x, 0)):
				return false
			if not agent_cell_passable(agent, previous + Vector2i(0, step.y)):
				return false
		previous = cell
	return true


func agent_cell_passable(
		agent: Dictionary,
		cell: Vector2i,
		clearance_cells := -1,
		allowed_terrain_mask := -1
	) -> bool:
	var clearance := int(agent["clearance"]) if clearance_cells < 0 else clearance_cells
	var terrain_mask := int(agent["terrain_mask"]) if allowed_terrain_mask < 0 else allowed_terrain_mask
	var pass_mask := int(agent["pass_mask"])
	if _runtime_map.is_passable(cell, pass_mask, clearance, terrain_mask):
		return true
	var allowed: Dictionary = agent.get("allowed_cells", {})
	if allowed.is_empty():
		return false
	for y in range(-clearance, clearance + 1):
		for x in range(-clearance, clearance + 1):
			var sample := cell + Vector2i(x, y)
			if not _runtime_map.grid.is_passable(sample, pass_mask):
				return false
			if terrain_mask != 0 and (terrain_mask & (1 << _runtime_map.grid.terrain_at(sample))) == 0:
				return false
			if _runtime_map.is_blocked(sample) and not allowed.has(sample):
				return false
	return true


func agent_cell_stoppable(
		agent: Dictionary,
		cell: Vector2i,
		clearance_cells := -1,
		allowed_terrain_mask := -1
	) -> bool:
	var clearance := int(agent["clearance"]) if clearance_cells < 0 else clearance_cells
	var terrain_mask := int(agent["terrain_mask"]) if allowed_terrain_mask < 0 else allowed_terrain_mask
	var pass_mask := int(agent["pass_mask"])
	if _runtime_map.is_stoppable(cell, pass_mask, clearance, terrain_mask):
		return true
	var allowed: Dictionary = agent.get("allowed_cells", {})
	if allowed.is_empty():
		return false
	for y in range(-clearance, clearance + 1):
		for x in range(-clearance, clearance + 1):
			var sample := cell + Vector2i(x, y)
			if not _runtime_map.grid.is_passable(sample, pass_mask):
				return false
			if terrain_mask != 0 and (terrain_mask & (1 << _runtime_map.grid.terrain_at(sample))) == 0:
				return false
			if (_runtime_map.is_blocked(sample) or _runtime_map.is_no_stop(sample)) \
			and not allowed.has(sample):
				return false
	return true
