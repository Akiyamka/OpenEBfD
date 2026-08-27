class_name GroundNavigation
extends RefCounted
## Ground agent per-tick steering: desired-velocity computation (slots/lanes/
## exit-point/yield), avoidance resolution, blocked/enemy reporting, and yield
## requests. Also owns the two path-computation entry points (`route_agent`,
## `simplify_path`) that every command handler and the reroute queue call to
## (re)plan an agent's route.

const NavConstantsScript := preload("res://scripts/units/navigation/shared/nav_constants.gd")
const MatchClockScript := preload("res://scripts/sim/match_clock.gd")

var _facade: Node
var _runtime_map
var _planner
var _avoidance
var _path_funnel
var _agents: Dictionary
var _registry
var _spatial_hash
var _path_follower
var _slot_allocator


func setup(
	facade: Node,
	runtime_map,
	planner,
	avoidance,
	path_funnel,
	agents: Dictionary,
	registry,
	spatial_hash,
	path_follower,
	slot_allocator
	) -> void:
	_facade = facade
	_runtime_map = runtime_map
	_planner = planner
	_avoidance = avoidance
	_path_funnel = path_funnel
	_agents = agents
	_registry = registry
	_spatial_hash = spatial_hash
	_path_follower = path_follower
	_slot_allocator = slot_allocator


## Computes the whole route synchronously: either a clear straight line or a
## native A* grid path, so the unit can move on the very next navigation tick.
## While an exit point is pending the unit is steered straight at it instead;
## routing takes over from there once it is reached.
func route_agent(agent: Dictionary, from: Vector3, destination: Vector3) -> void:
	agent["path"] = [] as Array[Vector2i]
	agent["path_index"] = 0
	agent["corridor"] = PackedInt32Array()
	agent["path_points"] = [] as Array[Vector3]
	agent["direct_path"] = false
	# A fresh route's segment 0 must not inherit a lane-rebase side cached
	# for the previous route's own segment 0 (see path_lane_target).
	agent["_lane_rebase_index"] = -1
	agent["_lane_rebase_side"] = 0
	if (agent["exit_point"] as Vector3).is_finite():
		return
	var stoppable_no_stop_cells: Dictionary = agent.get("allowed_cells", {}).duplicate()
	if bool(agent.get("no_stop_destination", false)):
		stoppable_no_stop_cells[_runtime_map.grid.world_to_grid(destination)] = true
	var start_cell: Vector2i = _runtime_map.grid.world_to_grid(from)
	var target_cell: Vector2i = _runtime_map.grid.world_to_grid(destination)
	if not _planner.is_reachable(
			start_cell, target_cell,
			int(agent["pass_mask"]), int(agent["clearance"]), int(agent["terrain_mask"]),
			stoppable_no_stop_cells
	):
		agent["route_unreachable"] = true
		return
	agent["route_unreachable"] = false
	agent["direct_path"] = _path_follower.has_clear_line(from, destination, agent)
	if not bool(agent["direct_path"]):
		var raw_path: Array[Vector2i] = _planner.find_path(
			start_cell, target_cell,
			int(agent["pass_mask"]), int(agent["clearance"]), int(agent["terrain_mask"]),
			stoppable_no_stop_cells
		)
		agent["path"] = simplify_path(raw_path, agent)
		var corridor := PackedInt32Array()
		corridor.resize(raw_path.size())
		for index in raw_path.size():
			corridor[index] = _runtime_map.grid.cell_index(raw_path[index])
		agent["corridor"] = corridor
		agent["path_points"] = _path_funnel.build(raw_path, agent, from, destination)


## AStarGrid2D returns every crossed cell. Keeping that raw list made every
## moving agent rediscover the same visible corner on every navigation tick.
## First retain only direction changes, then greedily join mutually visible
## turns. Runtime steering consequently follows a handful of stable waypoints.
func simplify_path(raw_path: Array[Vector2i], agent: Dictionary) -> Array[Vector2i]:
	if raw_path.size() <= 2:
		return raw_path
	var turns: Array[Vector2i] = [raw_path[0]]
	var previous_direction := (raw_path[1] - raw_path[0]).sign()
	for index in range(2, raw_path.size()):
		var direction := (raw_path[index] - raw_path[index - 1]).sign()
		if direction != previous_direction:
			turns.append(raw_path[index - 1])
			previous_direction = direction
	turns.append(raw_path.back())
	if turns.size() <= 2:
		return turns

	var result: Array[Vector2i] = [turns[0]]
	var anchor_index := 0
	while anchor_index < turns.size() - 1:
		var furthest_visible := anchor_index + 1
		var from: Vector3 = _runtime_map.grid.grid_to_world(turns[anchor_index])
		for probe_index in range(anchor_index + 2, turns.size()):
			var to: Vector3 = _runtime_map.grid.grid_to_world(turns[probe_index])
			if not _path_follower.has_clear_line(from, to, agent):
				break
			furthest_visible = probe_index
		result.append(turns[furthest_visible])
		anchor_index = furthest_visible
	return result


## World-space waypoints the follower actually steers toward. Normally the
## funnel output computed by `route_agent`; falls back to mapping the compact
## grid `path` through `grid_to_world` when `path_points` was never computed
## (an agent whose `path` a test set directly without going through
## `route_agent`, so it never got a funnel pass at all).
func path_points_for(agent: Dictionary) -> Array[Vector3]:
	var path_points: Array[Vector3] = agent.get("path_points", [])
	if not path_points.is_empty():
		return path_points
	var path: Array = agent["path"]
	var result: Array[Vector3] = []
	for cell in path:
		result.append(_runtime_map.grid.grid_to_world(cell))
	return result


func desired_velocity(agent: Dictionary) -> Vector3:
	var unit: Node3D = agent["unit"]
	# simulation_position(), not global_position, since slice R3: every number
	# below is a steering decision taken inside the tick, so it must come from
	# the store rather than the node's mirror. Read once for the whole function
	# -- the accessor resolves the owning Match by walking this node's
	# ancestors (MatchLookup._live_match) where the field read was free, and
	# nothing between here and the return moves the unit (route_agent only
	# rewrites agent keys). `unit` stays a bare Node3D, so the call is
	# duck-typed and a test double has to answer it.
	var unit_position: Vector3 = unit.simulation_position()
	agent["steering_target"] = unit_position
	agent["_arrival_speed_limited"] = false
	if bool(agent["hold"]):
		return Vector3.ZERO
	if float(agent["yield_remaining"]) > 0.0:
		agent["steering_target"] = unit_position \
			+ (agent["yield_direction"] as Vector3) * maxf(float(agent["radius"]) * 2.0, 2.0)
		return (agent["yield_direction"] as Vector3) * _unit_speed(unit) * 0.7
	var exit_point: Vector3 = agent["exit_point"]
	if exit_point.is_finite():
		var exit_offset := exit_point - unit_position
		exit_offset.y = 0.0
		if exit_offset.length() > maxf(_arrival_radius(unit), float(agent["radius"]) * 0.35):
			agent["steering_target"] = exit_point
			var exit_speed := _arrival_limited_speed(
				agent, _unit_speed(unit), exit_offset.length()
			)
			return exit_offset.normalized() * exit_speed
		agent["exit_point"] = Vector3.INF
		route_agent(agent, unit_position, agent["destination"])
	var destination: Vector3 = agent["destination"]
	var offset := destination - unit_position
	offset.y = 0.0
	agent["steering_target"] = destination
	var arrival: float = _facade.arrival_tolerance(unit)
	if offset.length() <= arrival:
		return Vector3.ZERO
	var speed: float = _unit_speed(unit)
	if int(agent["mode"]) == NavConstantsScript.MoveMode.FORMATION:
		speed = minf(speed, float(agent["group_speed"]))
	var direction := Vector3.ZERO
	var final_approach := bool(agent["direct_path"])
	var path: Array = agent["path"]
	if bool(agent["direct_path"]):
		direction = offset.normalized()
	elif not path.is_empty():
		var path_points := path_points_for(agent)
		var path_index := int(agent["path_index"])
		if path_index == 0 and path_points.size() > 1:
			path_index = 1
		path_index = clampi(path_index, 0, path_points.size() - 1)
		path_index = _path_follower.advanced_path_index(
			agent, path_points, path_index, unit_position, speed
		)
		agent["path_index"] = path_index
		var steering_target: Vector3 = _path_follower.path_steering_target(
			agent, path_points, path_index, unit_position, speed
		)
		steering_target = _path_follower.path_lane_target(
			agent, path_points, path_index, unit_position, steering_target, speed
		)
		agent["steering_target"] = steering_target
		direction = unit_position.direction_to(steering_target)
		direction.y = 0.0
		direction = direction.normalized()
		final_approach = path_index >= path_points.size() - 1
	if direction.is_zero_approx():
		return Vector3.ZERO
	if final_approach:
		speed = _arrival_limited_speed(agent, speed, offset.length())
	return direction * speed


## Full cruise speed may cover more than the remaining final segment in one
## fixed simulation tick. Limit only that last step so it lands on the target
## instead of crossing it and reversing direction on the following tick.
func _arrival_limited_speed(agent: Dictionary, speed: float, distance: float) -> float:
	var limited := minf(speed, distance * float(MatchClockScript.TICKS_PER_SECOND))
	agent["_arrival_speed_limited"] = limited < speed
	return limited


## A yielding friend steps sideways out of the requester's lane (toward the
## side it is already offset to), not along it — walking the lane keeps it in
## front of the requester and drags it deep into the crowd.
func yield_direction(requester: Node3D, friend: Node3D, desired: Vector3) -> Vector3:
	var lateral := desired.normalized().cross(Vector3.UP)
	var friend_position: Vector3 = friend.simulation_position()
	var requester_position: Vector3 = requester.simulation_position()
	var side := friend_position - requester_position
	side.y = 0.0
	if lateral.dot(side) < 0.0:
		lateral = -lateral
	return lateral.normalized()


func request_yield(unit: Node3D, direction: Vector3) -> void:
	# Yield is internal steering, not an order. It deliberately bypasses
	# Unit.prepare_navigation_order(), so action state machines and the player's
	# current command remain intact. Commanded agents resume their reserved
	# destination when the short displacement expires (see tick()).
	var agent: Dictionary = _registry.agent_for(_agents, unit)
	if agent.is_empty() or bool(agent["hold"]) or direction.is_zero_approx():
		return
	# A unit already following a route normally clears the queue by itself. The
	# request mainly displaces idle friendlies that occupy a choke point.
	if is_en_route(agent) and float(agent["yield_remaining"]) <= 0.0:
		return
	agent["yield_direction"] = direction
	agent["yield_remaining"] = NavConstantsScript.FRIENDLY_YIELD_SECONDS
	_agents[unit.get_instance_id()] = agent


func is_en_route(agent: Dictionary) -> bool:
	if int(agent["command_id"]) <= 0:
		return false
	var unit: Node3D = agent["unit"]
	var offset: Vector3 = (agent["destination"] as Vector3) - unit.simulation_position()
	offset.y = 0.0
	return offset.length() > maxf(_arrival_radius(unit), float(agent["radius"]) * 0.35)


## Per-agent steering resolution for one navigation tick, in the exact order
## the facade's `_ordered_agents()` list provides (determinism: yield/claim/
## resolved-position bookkeeping all depend on this order being stable).
##
## ORCA needs every neighbour's avoidance line built from the *same* instant
## (a precondition of reciprocity): a two-phase split keeps every agent's
## position frozen at the tick's start while `_new_velocity` is computed for
## the whole set, then applies the results (separation/stabilize/
## `navigation_step`) in a second pass, in the exact same id order both times.
func tick(delta: float, ordered: Array[Dictionary], buckets: Dictionary) -> void:
	var largest_radius := 0.0
	for value in ordered:
		largest_radius = maxf(largest_radius, float(value["radius"]))
	# Phase 1 (compute): every agent still sits at its start-of-tick position,
	# so neighbour lines built here are mutually consistent regardless of
	# iteration order.
	for agent in ordered:
		var unit: Node3D = agent["unit"]
		agent["_tick_start_position"] = unit.simulation_position()
		agent["_v_pref"] = desired_velocity(agent)
	for agent in ordered:
		var unit: Node3D = agent["unit"]
		var nearby: Array = _spatial_hash.nearby(
			unit.simulation_position(),
			buckets,
			float(agent["radius"]) + largest_radius
		)
		var result: Dictionary = _avoidance.resolve_velocity(
			agent, agent["_v_pref"], delta, nearby, {}
		)
		agent["_new_velocity"] = result["velocity"]
		agent["_enemies"] = result["enemies"]
		agent["_friends"] = result["friends"]
	# Phase 2 (apply): separation/passability/stabilize + navigation_step, in
	# the same order; `orca_velocity` is then the tick's actually-achieved
	# velocity (not `_new_velocity`), so a turn-in-place tick correctly
	# reports near-zero motion to next tick's reciprocal lines.
	var resolved_positions: Dictionary = {}
	for agent in ordered:
		var unit: Node3D = agent["unit"]
		var desired: Vector3 = agent["_v_pref"]
		var velocity: Vector3 = agent["_new_velocity"]
		var nearby: Array = _spatial_hash.nearby(
			unit.simulation_position(),
			buckets,
			float(agent["radius"]) + largest_radius
		)
		_apply_resolved_velocity(
			delta, agent, unit, desired, velocity,
			agent["_enemies"], agent["_friends"], nearby, resolved_positions
		)
		var start_position: Vector3 = agent["_tick_start_position"]
		# Read again rather than reusing any earlier value: _apply_resolved_velocity
		# above has run navigation_step, which moves the unit through
		# Unit.set_simulation_position(), so the store already carries this tick's
		# landing point.
		var landed_position: Vector3 = unit.simulation_position()
		var achieved_velocity: Vector3 = (landed_position - start_position) / delta
		agent["orca_velocity"] = achieved_velocity
		# Recorded here (end of this agent's phase-2 iteration, after
		# `orca_velocity` above has already been overwritten with THIS tick's
		# solver output) so next tick's `_apply_resolved_velocity` reads the
		# actually-achieved displacement of the tick that just finished, not
		# the not-yet-clamped solver output `orca.resolve_velocity` wrote
		# earlier this same tick.
		agent["_achieved_velocity"] = achieved_velocity


## Shared apply step (phase 2): blocked/enemy reporting, yield expiry, elastic
## separation, non-holonomic stabilization, and the actual `navigation_step`.
func _apply_resolved_velocity(
		delta: float,
		agent: Dictionary,
		unit: Node3D,
		desired: Vector3,
		velocity_in: Vector3,
		enemies: Array[Node3D],
		friends: Array[Node3D],
		nearby: Array,
		resolved_positions: Dictionary
	) -> void:
	var velocity := velocity_in
	# A turn-in-place tick reports non-zero solver velocity (`velocity`) but
	# ~zero actual displacement, since the chassis rate limiter in
	# `stabilize_velocity` (still ahead of us this tick) clamps the achieved
	# motion toward zero. `_achieved_velocity` holds the PREVIOUS tick's real
	# displacement (see where `tick()` writes it below), so it still catches
	# such a stall this check would otherwise miss — letting friendly-yield
	# (`FRIENDLY_YIELD_TRIGGER_SECONDS`) and the squeeze gate
	# (`orca_avoidance.gd`'s `was_stalled`) trigger during it.
	var achieved: Vector3 = agent.get("_achieved_velocity", Vector3.ZERO)
	if desired.length_squared() > 0.01 \
	and (velocity.length_squared() < 0.01 or achieved.length_squared() < 0.01):
		agent["blocked_time"] = float(agent["blocked_time"]) + delta
	else:
		agent["blocked_time"] = 0.0
		agent["reported_enemy"] = false
	if float(agent["blocked_time"]) >= NavConstantsScript.ENEMY_BLOCK_SECONDS and not bool(agent["reported_enemy"]):
		if not enemies.is_empty():
			agent["reported_enemy"] = true
			_facade.enemy_blocked.emit(unit, enemies)
			if unit.has_method("navigation_blocked_by_enemy"):
				unit.call("navigation_blocked_by_enemy", enemies)
	if float(agent["blocked_time"]) >= NavConstantsScript.FRIENDLY_YIELD_TRIGGER_SECONDS:
		for friend in friends:
			request_yield(friend, yield_direction(unit, friend, desired))
	if float(agent["yield_remaining"]) > 0.0:
		agent["yield_remaining"] = maxf(0.0, float(agent["yield_remaining"]) - delta)
		if is_zero_approx(float(agent["yield_remaining"])):
			var unit_position: Vector3 = unit.simulation_position()
			if int(agent["command_id"]) > 0:
				# A commanded unit owns a unique reserved block nobody else
				# will claim: walk back to it once the passer is through.
				route_agent(agent, unit_position, agent["destination"])
			else:
				# An idle unit displaced off a choke point must not return
				# (it would displace the passer forever); it parks on the
				# nearest free grid block instead.
				agent["destination"] = _slot_allocator.snapped_parking(
					_agents, agent, unit_position + velocity * delta
				)
				agent["reserved"] = true
				route_agent(agent, unit_position, agent["destination"])
	# Elastic overlap resolution normally lets overlapping units push each
	# other apart. A held unit, however, owns its exact position (for example
	# a harvester unloading on a refinery pad); only the other agent may move
	# to resolve an overlap with it. A unit standing on its firing position
	# owns its spot the same way and for the same reason it must not be shoved:
	# being displaced restarts its fire clip, and walking back to `destination`
	# restarts it again. `separation_velocity` is per-agent, so the arriving
	# unit still pushes itself clear of the overlap.
	var separation: Vector3 = Vector3.ZERO \
		if bool(agent["hold"]) or bool(agent.get("firing_anchor", false)) \
		else _avoidance.separation_velocity(agent, nearby)
	if not separation.is_zero_approx():
		var total: Vector3 = (velocity + separation).limit_length(_unit_speed(unit))
		# Separation may cross friends, but it must not turn the already-safe
		# steering result into motion through an enemy or forbidden terrain.
		if _avoidance.motion_is_passable(agent, total * delta) \
		and _avoidance.enemy_sweep_fraction(
			agent, total * delta, nearby, resolved_positions
		) >= 0.999:
			velocity = total
			# An idle unit has no spot to defend; it goes where it is pushed
			# instead of fighting its way back into the overlap.
			if int(agent["command_id"]) <= 0 and not bool(agent["hold"]):
				agent["destination"] = unit.simulation_position() + velocity * delta
	velocity = _avoidance.stabilize_velocity(
		agent, velocity, delta, nearby, resolved_positions
	)
	# ORCA already treats the preferred speed as a hard maximum, but elastic
	# separation is added afterwards. Preserve the reduced final-step maximum
	# even when a nearby friendly body also pushes this moving unit.
	if bool(agent.get("_arrival_speed_limited", false)):
		velocity = velocity.limit_length(desired.length())
	_agents[unit.get_instance_id()] = agent
	if unit.has_method("navigation_step"):
		unit.call("navigation_step", velocity, delta)
	# Unit may spend this update turning in place when its rules do not allow
	# simultaneous translation and rotation. Record the actual position so
	# later swept-disc checks do not reserve movement that never happened.
	resolved_positions[unit.get_instance_id()] = unit.simulation_position()


static func _unit_speed(unit: Node3D) -> float:
	if unit.has_method("navigation_move_speed"):
		return maxf(float(unit.call("navigation_move_speed")), 0.0)
	var value = unit.get("move_speed")
	return maxf(float(value), 0.0) if value != null else 0.0


static func _arrival_radius(unit: Node3D) -> float:
	var value = unit.get("arrival_radius")
	return float(value) if value != null else 0.2
