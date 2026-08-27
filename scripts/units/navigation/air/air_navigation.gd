class_name AirNavigation
extends RefCounted
## Airborne agent movement: a straight line to the destination clamped to the
## map's world bounds, with no A* and no notion of ground buildings/terrain —
## a cruising/hovering flyer sees neither. Slots, lanes, yield and the ground
## planner do not exist here; group orders only get a simple spread offset so
## several flyers sent to the same point do not stack on the same cell.

const MapNavigationGridScript := preload("res://scripts/world/map/map_navigation_grid.gd")

## Air-air vertical avoidance: fixed altitude offset (world units) each side of
## a converging pair of flying agents takes to fly over/under the other. The
## flight controller blends the agent's actual altitude toward this target
## (and decays it back toward 0 once clear) with its own response rate.
const VERTICAL_SEPARATION_OFFSET := 3.0

## World-space fan-out spacing between flyers sent to the same shared target,
## reusing GroundSlotAllocator's pure ring-index math (`crowd_offset`) — it has
## no grid dependency, only integer ring positions to scale.
const GROUP_SPREAD_SPACING := 3.0

## Untyped (unlike the ground modules' `Node` facade reference): flight_run.gd
## exercises `desired_velocity` against a minimal RefCounted stand-in that
## only implements the couple of methods this module actually calls, to prove
## the air pipeline has no grid dependency at all.
var _facade
var _runtime_map
var _avoidance
var _agents: Dictionary
var _spatial_hash
var _slot_allocator


func setup(
	facade,
	runtime_map = null,
	avoidance = null,
	agents: Dictionary = {},
	spatial_hash = null,
	slot_allocator = null
	) -> void:
	_facade = facade
	_runtime_map = runtime_map
	_avoidance = avoidance
	_agents = agents
	_spatial_hash = spatial_hash
	_slot_allocator = slot_allocator


## Per-order entry point: every command path (command_move's air branch today;
## a future land/dock order later) funnels through here, so bounds-clamping
## the destination has exactly one place to live. No path state to compute —
## an air agent always flies the straight line to `agent["destination"]`.
func route_agent(agent: Dictionary, _from: Vector3, destination: Vector3) -> void:
	var unit: Node3D = agent["unit"]
	var bounded_destination := clamp_to_bounds(destination)
	# This is an explicit order state, not an inference from velocity. A
	# fixed-wing Circles unit keeps moving while idle, so its position alone
	# cannot distinguish a completed order from a still-active one.
	agent["active_order"] = true
	if unit.has_method("flight_set_circles_order"):
		unit.call("flight_set_circles_order", bounded_destination)
	agent["path"] = [] as Array[Vector2i]
	agent["path_index"] = 0
	agent["corridor"] = PackedInt32Array()
	agent["direct_path"] = true
	agent["destination"] = bounded_destination


func clamp_to_bounds(world_position: Vector3) -> Vector3:
	var grid = _runtime_map.grid
	if grid == null:
		return world_position
	var bounds: AABB = grid.world_bounds
	if bounds.size.x <= 0.0 or bounds.size.z <= 0.0:
		return world_position
	var result := world_position
	result.x = clampf(result.x, bounds.position.x, bounds.position.x + bounds.size.x)
	result.z = clampf(result.z, bounds.position.z, bounds.position.z + bounds.size.z)
	return result


func in_bounds(world_position: Vector3) -> bool:
	var grid = _runtime_map.grid
	if grid == null:
		return false
	var bounds: AABB = grid.world_bounds
	if bounds.size.x <= 0.0 or bounds.size.z <= 0.0:
		return false
	return world_position.x >= bounds.position.x and world_position.x <= bounds.position.x + bounds.size.x \
		and world_position.z >= bounds.position.z and world_position.z <= bounds.position.z + bounds.size.z


## Group-order destinations: same shared target as a ground FREE move, spread
## out with the same ring pattern so several flyers do not all aim at the
## exact same point, but with no slot claiming/parking — every position is
## simply available.
func target_assignments(agents: Dictionary, units: Array[Node3D], world_target: Vector3) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for index in units.size():
		var unit := units[index]
		var agent: Dictionary = agents[unit.get_instance_id()]
		var offset: Vector2i = _slot_allocator.crowd_offset(index)
		var position := world_target + Vector3(float(offset.x), 0.0, float(offset.y)) * GROUP_SPREAD_SPACING
		position = clamp_to_bounds(position)
		position.y = world_target.y
		result.append({
			"unit": unit,
			"agent_id": agent["id"],
			"slot_id": index,
			"position": position,
			"available": true,
		})
	return result


func desired_velocity(agent: Dictionary) -> Vector3:
	var unit: Node3D = agent["unit"]
	agent["steering_target"] = agent["destination"]
	if unit.has_method("flight_navigation_is_locked") and bool(unit.call("flight_navigation_is_locked")):
		return Vector3.ZERO
	if bool(agent["hold"]):
		return Vector3.ZERO
	if unit.has_method("flight_circles_enabled") and bool(unit.call("flight_circles_enabled")):
		return unit.call("flight_circles_desired_velocity") as Vector3
	var destination: Vector3 = agent["destination"]
	# simulation_position(), not global_position, since slice R5: this offset is
	# both the arrival test and the steering velocity for the whole tick, the
	# air twin of the read GroundNavigation.desired_velocity() moved in R3.
	# `unit` stays a bare Node3D -- this module is duck-typed on the agent's
	# node like the rest of navigation, so the call resolves at runtime and a
	# test double has to answer it. That is also why the type is written out
	# rather than inferred: a dynamic call's result is a Variant, and
	# project.godot promotes an inferred Variant to a parse error.
	var offset: Vector3 = destination - unit.simulation_position()
	offset.y = 0.0
	if offset.length() <= _facade.arrival_tolerance(unit):
		return Vector3.ZERO
	return offset.normalized() * _unit_speed(unit)


## Per-agent steering resolution for one navigation tick, mirroring
## GroundNavigation.tick's shape but without any of the ground-only pieces
## (slots/lanes/exit-point/yield/passability). Vertical splitting handles
## air-air convergence; `separation_velocity` (reused as-is from
## UnitLocalAvoidance — it is pure radius/id geometry, not grid-aware) handles
## lateral spacing.
func tick(delta: float, ordered: Array[Dictionary], buckets: Dictionary) -> void:
	var largest_radius := 0.0
	for value in ordered:
		largest_radius = maxf(largest_radius, float(value["radius"]))
	for agent in ordered:
		var unit: Node3D = agent["unit"]
		var desired := desired_velocity(agent)
		# simulation_position(), not global_position, since slice R5, and this
		# read is not independent of R4: NavSpatialHash.build() has keyed these
		# buckets from simulation_position() since that slice, so looking them up
		# with a node position would file an agent in one bucket and search for
		# it in another the moment the two disagreed. GroundNavigation.tick()
		# already reads the store here; this is the same pairing on the air side.
		var nearby: Array = _spatial_hash.nearby(
			unit.simulation_position(), buckets, float(agent["radius"]) + largest_radius
		)
		var blockers := []
		for other in nearby:
			if other["unit"] != unit:
				blockers.append(other)
		var flight_locked := unit.has_method("flight_navigation_is_locked") \
			and bool(unit.call("flight_navigation_is_locked"))
		if flight_locked:
			# Landing/pickup owns the horizontal body transform. In particular,
			# lateral separation must not slide an aircraft that has requested a
			# zero navigation velocity for a vertical authored sequence.
			_decay_vertical_offset(agent)
		elif not desired.is_zero_approx():
			_resolve_vertical_conflict(agent, blockers)
		else:
			_decay_vertical_offset(agent)
		var velocity := desired
		if flight_locked:
			velocity = Vector3.ZERO
		else:
			var separation: Vector3 = _avoidance.separation_velocity(agent, nearby)
			if not separation.is_zero_approx():
				velocity = (velocity + separation).limit_length(_unit_speed(unit))
		_agents[unit.get_instance_id()] = agent
		if unit.has_method("navigation_step"):
			unit.call("navigation_step", velocity, delta)
		if unit.has_method("flight_consume_circles_order_completed") \
		and bool(unit.call("flight_consume_circles_order_completed")):
			agent["active_order"] = false
			# simulation_position(), not global_position, since slice R5. The
			# destination is simulation state the tick reads back every tick
			# afterwards, so it must not be seeded from the mirror -- and it is
			# read here, after navigation_step() above has already moved the
			# unit this tick, rather than hoisted with the two reads above.
			# That ordering also makes this the one read of the 24 R5 moved
			# that no test can bind: navigation_step() ends in
			# Unit.set_simulation_position(), so store and node agree again by
			# the time this line runs and a manufactured disagreement cannot
			# survive to be observed here. The rule is what holds it -- see
			# tests/navigation/store_reads_run.gd's header.
			agent["destination"] = unit.simulation_position()
		_agents[unit.get_instance_id()] = agent


## Deterministic 2-way split: each conflicting air-air pair independently
## agrees on who goes high/low by comparing stable agent ids, so neither side
## needs the other's decision synchronized. Not a full N-way stack solver —
## only pairwise conflicts the lateral solver already flagged are resolved.
func _resolve_vertical_conflict(agent: Dictionary, blockers: Array) -> void:
	var unit: Node3D = agent["unit"]
	var agent_id := int(agent["id"])
	for other in blockers:
		if int(other["pass_mask"]) != MapNavigationGridScript.PASS_AIR:
			continue
		var offset := VERTICAL_SEPARATION_OFFSET if agent_id < int(other["id"]) else -VERTICAL_SEPARATION_OFFSET
		if unit.has_method("flight_set_vertical_offset"):
			unit.call("flight_set_vertical_offset", offset)
		return
	_decay_vertical_offset(agent)


func _decay_vertical_offset(agent: Dictionary) -> void:
	var unit: Node3D = agent["unit"]
	if unit != null and unit.has_method("flight_set_vertical_offset"):
		unit.call("flight_set_vertical_offset", 0.0)


static func _unit_speed(unit: Node3D) -> float:
	if unit.has_method("navigation_move_speed"):
		return maxf(float(unit.call("navigation_move_speed")), 0.0)
	var value = unit.get("move_speed")
	return maxf(float(value), 0.0) if value != null else 0.0
