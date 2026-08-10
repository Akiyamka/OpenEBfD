class_name UnitNavigationSystem
extends Node
## Match-scoped RTS navigation coordinator. It owns path work and destination
## assignment, delegates short-range collision steering to UnitLocalAvoidance,
## and leaves presentation/terrain following to Unit.

const UnitNavigationMapScript := preload("res://scripts/units/navigation/unit_navigation_map.gd")
const UnitNavigationPlannerScript := preload("res://scripts/units/navigation/unit_navigation_planner.gd")
const UnitLocalAvoidanceScript := preload("res://scripts/units/navigation/unit_local_avoidance.gd")
const UnitNavigationDebugScript := preload("res://scripts/units/navigation/unit_navigation_debug.gd")
const NavAgentRegistryScript := preload("res://scripts/units/navigation/shared/nav_agent_registry.gd")
const NavSpatialHashScript := preload("res://scripts/units/navigation/shared/nav_spatial_hash.gd")
const GroundSlotAllocatorScript := preload("res://scripts/units/navigation/ground/ground_slot_allocator.gd")
const GroundPathFollowerScript := preload("res://scripts/units/navigation/ground/ground_path_follower.gd")
const NavBlockerTrackerScript := preload("res://scripts/units/navigation/shared/nav_blocker_tracker.gd")
const GroundNavigationScript := preload("res://scripts/units/navigation/ground/ground_navigation.gd")
const PathFunnelScript := preload("res://scripts/units/navigation/ground/path_funnel.gd")
const AirNavigationScript := preload("res://scripts/units/navigation/air/air_navigation.gd")
const NavConstantsScript := preload("res://scripts/units/navigation/shared/nav_constants.gd")
const MapNavigationGridScript := preload("res://scripts/world/map/map_navigation_grid.gd")

signal destination_slots_assigned(command_id: int, assignments: Array[Dictionary])
@warning_ignore("unused_signal") # Public integration hook; intentionally not emitted here yet.
signal enemy_blocked(unit: Node3D, blockers: Array[Node3D])

const NAVIGATION_TICK_RATE := NavConstantsScript.NAVIGATION_TICK_RATE
const BLOCKER_REFRESH_SECONDS := NavConstantsScript.BLOCKER_REFRESH_SECONDS
const ENEMY_BLOCK_SECONDS := NavConstantsScript.ENEMY_BLOCK_SECONDS
const FRIENDLY_YIELD_SECONDS := NavConstantsScript.FRIENDLY_YIELD_SECONDS
const FRIENDLY_YIELD_TRIGGER_SECONDS := NavConstantsScript.FRIENDLY_YIELD_TRIGGER_SECONDS
const CELL_BUCKET_SIZE := NavConstantsScript.CELL_BUCKET_SIZE
## Blocked cells must cover exactly the footprint the placement grid reserves.
const OCCUPY_CELL_SPAN := NavConstantsScript.OCCUPY_CELL_SPAN
const SLOT_SEARCH_RADIUS := NavConstantsScript.SLOT_SEARCH_RADIUS
## Ticks a unit sits out of assignment trading after a swap (anti flip-flop).
const SWAP_COOLDOWN_TICKS := NavConstantsScript.SWAP_COOLDOWN_TICKS
## Free cells kept between parked footprints, so a standing formation stays
## permeable: small units can thread the lanes between the parking blocks.
const PARKING_GAP_CELLS := NavConstantsScript.PARKING_GAP_CELLS
## Parallel route lanes must sit outside the same soft personal-space field
## used by local avoidance. Otherwise units technically have different targets
## but still spend the whole trip steering away from each other.
const ROUTE_LANE_COMFORT_RADIUS_FACTOR := NavConstantsScript.ROUTE_LANE_COMFORT_RADIUS_FACTOR
## Never let a slow navigation tick create an unbounded catch-up loop. Dropping
## excess simulation time makes units briefly slow down under overload, but the
## render thread can recover instead of spending every following frame on old
## navigation work.
const MAX_CATCH_UP_TICKS := NavConstantsScript.MAX_CATCH_UP_TICKS
## A building-blocker change only reroutes agents whose stored corridor or
## destination block actually overlaps the changed cells (see
## `_agent_route_intersects`); this caps how many of those dirty agents get an
## actual `find_path` re-run per navigation tick so a large simultaneous change
## (e.g. a building placed in the middle of a crowd) cannot burst every
## commanded agent's A* in one frame.
const REROUTE_BUDGET_PER_TICK := NavConstantsScript.REROUTE_BUDGET_PER_TICK

var runtime_map = UnitNavigationMapScript.new()
var planner = UnitNavigationPlannerScript.new()
var avoidance = UnitLocalAvoidanceScript.new()
var navigation_debug = UnitNavigationDebugScript.new()
var registry := NavAgentRegistryScript.new()
var spatial_hash := NavSpatialHashScript.new()
var slot_allocator := GroundSlotAllocatorScript.new()
var path_follower := GroundPathFollowerScript.new()
var path_funnel := PathFunnelScript.new()
var blocker_tracker := NavBlockerTrackerScript.new()
var ground_navigation := GroundNavigationScript.new()
var air_navigation := AirNavigationScript.new()

var _agents: Dictionary = {}
var _next_command_id := 1
var _navigation_tick_index := 0
var _navigation_accumulator := 0.0
var _blocker_refresh_remaining := 0.0
var _command_log: Array[Dictionary] = []
var _debug_enabled := false
func _ready() -> void:
	if navigation_debug.get_parent() == null:
		navigation_debug.name = "NavigationDebug"
		add_child(navigation_debug)
	navigation_debug.set_enabled(_debug_enabled)
	if not get_tree().node_added.is_connected(_on_tree_node_added):
		get_tree().node_added.connect(_on_tree_node_added)


func _exit_tree() -> void:
	if get_tree() != null and get_tree().node_added.is_connected(_on_tree_node_added):
		get_tree().node_added.disconnect(_on_tree_node_added)


func setup(source_grid: MapNavigationGrid) -> bool:
	if not runtime_map.setup(source_grid):
		push_error("UnitNavigationSystem: navigation grid is unavailable")
		return false
	planner.setup(runtime_map)
	avoidance.setup(runtime_map)
	registry.setup(self, runtime_map, planner, avoidance)
	slot_allocator.setup(runtime_map, planner, path_follower, ground_navigation, navigation_tick_index)
	path_follower.setup(self, runtime_map, avoidance, registry, slot_allocator, ground_navigation)
	path_funnel.setup(runtime_map, path_follower)
	blocker_tracker.setup(
		self, runtime_map, _agents, registry, slot_allocator, path_follower, ground_navigation,
		_owns_node
	)
	ground_navigation.setup(
		self, runtime_map, planner, avoidance, path_funnel,
		_agents, registry, spatial_hash, path_follower, slot_allocator
	)
	air_navigation.setup(self, runtime_map, avoidance, _agents, spatial_hash, slot_allocator)
	_refresh_building_blockers()
	if is_inside_tree():
		for node in get_tree().get_nodes_in_group("units"):
			if node is Node3D and _owns_node(node):
				register_unit(node)
	return true


func register_unit(unit: Node3D) -> int:
	return registry.register_unit(_agents, unit, _debug_enabled)


func unregister_unit(unit: Node3D) -> void:
	registry.unregister_unit(_agents, unit)


func set_debug_enabled(value: bool) -> void:
	_debug_enabled = value
	navigation_debug.set_enabled(value)
	for agent_value in _agents.values():
		var unit: Node3D = (agent_value as Dictionary).get("unit")
		if is_instance_valid(unit) and unit.has_method("set_navigation_debug_visible"):
			unit.call("set_navigation_debug_visible", value)
	if value:
		_refresh_navigation_debug()


func debug_enabled() -> bool:
	return _debug_enabled


func navigation_tick_index() -> int:
	return _navigation_tick_index


func set_hold_position(unit: Node3D, active: bool) -> void:
	var agent: Dictionary = registry.agent_for(_agents, unit)
	if agent.is_empty():
		return
	agent["hold"] = active
	if active:
		agent["active_order"] = false
		if unit.has_method("flight_clear_circles_order"):
			unit.call("flight_clear_circles_order")
		avoidance.reset_agent(agent)
		agent["path"] = [] as Array[Vector2i]
		agent["destination"] = unit.global_position
		agent["exit_point"] = Vector3.INF
		agent["yield_remaining"] = 0.0
		agent["yield_direction"] = Vector3.ZERO
		agent["reserved"] = true
	_agents[unit.get_instance_id()] = agent


## Read-only counterpart of an ordinary move order. It checks the exact
## clicked destination against each unit's movement profile without preparing
## the unit, changing its route, or reserving a parking slot.
func can_move_to(units: Array, world_target: Vector3) -> bool:
	if runtime_map.grid == null:
		return false
	var target_cell: Vector2i = runtime_map.grid.world_to_grid(world_target)
	var allow_no_stop: bool = runtime_map.is_no_stop(target_cell)
	for value in units:
		var unit := value as Node3D
		if unit == null:
			continue
		var agent: Dictionary = registry.movement_probe_for(_agents, unit)
		if int(agent["pass_mask"]) == MapNavigationGridScript.PASS_AIR \
		and registry.domain_for({"pass_mask": agent["pass_mask"], "unit": unit}) == NavAgentRegistryScript.Domain.AIR:
			if air_navigation.in_bounds(world_target):
				return true
			continue
		if _ground_target_is_legal(agent, world_target, allow_no_stop) \
		and _ground_target_is_reachable(unit, agent, world_target, allow_no_stop):
			return true
	return false


## `exit_point` is a mandatory first waypoint for every unit in the command: a
## production building's front exit that the unit walks straight to before
## regular routing takes over (local steering may cross the building's own
## cells on the way).
func command_move(units: Array, world_target: Vector3, mode := NavConstantsScript.MoveMode.FREE, exit_point := Vector3.INF) -> Array[Dictionary]:
	var ordered: Array[Node3D] = []
	for value in units:
		var unit := value as Node3D
		if unit == null:
			continue
		register_unit(unit)
		ordered.append(unit)
	ordered.sort_custom(func(a: Node3D, b: Node3D) -> bool:
		return int(a.get_meta(&"navigation_agent_id", 0)) < int(b.get_meta(&"navigation_agent_id", 0))
	)
	# A landed flyer swept into a group selection never went through
	# Unit.move_to() (command controllers call this facade directly), so its
	# own takeoff redirect never ran. Peel it off here and let it take off
	# through the normal single-unit path instead of being routed as ground.
	var remaining: Array[Node3D] = []
	for unit in ordered:
		var config = unit.get("unit_definition")
		var flies := config != null and bool(config.can_fly)
		if flies and unit.has_method("flight_is_landed") and bool(unit.call("flight_is_landed")) \
		and unit.has_method("move_to"):
			unit.call("move_to", world_target, exit_point)
		else:
			remaining.append(unit)
	ordered = remaining
	# Reject an exact, otherwise legal ground destination when it belongs to a
	# different connected component. Doing this before prepare_navigation_order
	# keeps an impossible click from cancelling the unit's current gameplay
	# action. Blocked clicks are retained: slot allocation deliberately turns
	# those into a reachable approach point on the unit's side of the obstacle.
	remaining = []
	var clicked_no_stop: bool = runtime_map.grid != null \
		and runtime_map.is_no_stop(runtime_map.grid.world_to_grid(world_target))
	for unit in ordered:
		var agent: Dictionary = registry.movement_probe_for(_agents, unit)
		var is_air := int(agent["pass_mask"]) == MapNavigationGridScript.PASS_AIR \
			and registry.domain_for({"pass_mask": agent["pass_mask"], "unit": unit}) == NavAgentRegistryScript.Domain.AIR
		if not is_air \
		and _ground_target_is_legal(agent, world_target, clicked_no_stop) \
		and not _ground_target_is_reachable(unit, agent, world_target, clicked_no_stop):
			continue
		remaining.append(unit)
	ordered = remaining
	var prepared: Array[Node3D] = []
	for unit in ordered:
		if unit.has_method("prepare_navigation_order") \
		and not bool(unit.call("prepare_navigation_order", world_target, exit_point, mode)):
			continue
		prepared.append(unit)
	ordered = prepared
	if ordered.is_empty() or runtime_map.grid == null:
		return []
	# Slot selection must use ordinary movement rules. In particular, a unit's
	# previous refinery-dock exception must not make that dock look like a legal
	# permanent destination for its next player order.
	var ground_units: Array[Node3D] = []
	var air_units: Array[Node3D] = []
	for unit in ordered:
		var agent: Dictionary = _agents[unit.get_instance_id()]
		avoidance.reset_agent(agent)
		registry.set_agent_rotation_envelope(agent, true)
		agent["allowed_cells"] = {}
		agent["no_stop_destination"] = false
		agent["departure_access"] = false
		agent["domain"] = registry.domain_for(agent)
		_agents[unit.get_instance_id()] = agent
		if int(agent["domain"]) == NavAgentRegistryScript.Domain.AIR:
			air_units.append(unit)
		else:
			ground_units.append(unit)

	var command_id := _next_command_id
	_next_command_id += 1
	var group_speed := _slowest_speed(ordered) if mode == NavConstantsScript.MoveMode.FORMATION else INF
	var assignments: Array[Dictionary] = []
	if not ground_units.is_empty():
		assignments += slot_allocator.assign_slots(_agents, ground_units, world_target, mode) \
			if mode == NavConstantsScript.MoveMode.FORMATION else slot_allocator.shared_target_assignments(
				_agents, ground_units, world_target
			)
	if not air_units.is_empty():
		assignments += air_navigation.target_assignments(_agents, air_units, world_target)
	var claim_radius := slot_allocator.claim_radius_for(_agents, ordered)
	for assignment in assignments:
		var unit: Node3D = assignment["unit"]
		var agent: Dictionary = _agents[unit.get_instance_id()]
		agent["destination"] = assignment["position"]
		# Formation slots are planned upfront; a FREE move flies each unit to
		# its shape-preserving aim point and lets it claim a parking block on
		# approach, searching center-out from the shared target.
		agent["no_stop_destination"] = bool(assignment.get("no_stop_destination", false))
		agent["reserved"] = mode == NavConstantsScript.MoveMode.FORMATION or bool(agent["no_stop_destination"])
		agent["claim_radius"] = claim_radius
		agent["claim_center"] = assignment.get("claim_center", world_target)
		agent["command_id"] = command_id
		agent["mode"] = mode
		agent["group_speed"] = group_speed
		agent["hold"] = false
		agent["blocked_time"] = 0.0
		agent["reported_enemy"] = false
		agent["exit_point"] = exit_point
		agent["allowed_cells"] = {}
		# A fresh order overrides an in-progress yield; a stale yield would keep
		# steering the unit aside and, on expiry, replace this destination with
		# wherever the unit happens to stand.
		agent["yield_remaining"] = 0.0
		agent["yield_direction"] = Vector3.ZERO
		_route_agent(agent, unit.global_position, assignment["position"])
		_agents[unit.get_instance_id()] = agent
		if unit.has_method("set_navigation_destination"):
			unit.call("set_navigation_destination", assignment["position"])
	slot_allocator.assign_route_lanes(_agents, ground_units, world_target)
	_command_log.append({
		"tick": _navigation_tick_index,
		"command_id": command_id,
		"mode": mode,
		"target": world_target,
		"agents": assignments.map(func(value: Dictionary): return value["agent_id"]),
		"slots": assignments.map(func(value: Dictionary): return value["position"]),
	})
	destination_slots_assigned.emit(command_id, assignments)
	return assignments


## Ordinary single-unit movement that starts on a reserved refinery pad.
## Unlike command_dock(), the destination is claimed with normal FREE-move
## parking rules, so several departing harvesters never reserve the same spice
## cell. `allowed_cells` exists only long enough to clear the refinery apron.
func command_depart(unit: Node3D, world_target: Vector3, allowed_cells: Dictionary) -> bool:
	if unit == null or allowed_cells.is_empty():
		return false
	var assignments := command_move([unit], world_target, NavConstantsScript.MoveMode.FREE)
	if assignments.is_empty():
		return false
	var agent: Dictionary = registry.agent_for(_agents, unit)
	registry.set_agent_rotation_envelope(agent, false)
	agent["allowed_cells"] = allowed_cells.duplicate()
	agent["departure_access"] = true
	_route_agent(agent, unit.global_position, agent["destination"])
	_agents[unit.get_instance_id()] = agent
	return bool(agent["direct_path"]) or not (agent["path"] as Array).is_empty()


## Exact single-unit parking order. `allowed_cells` normally contains the d/p
## cells of the refinery that owns the reserved dock. Only this agent may stop
## there; they remain ordinary no-stop transit space for every other unit.
func command_dock(unit: Node3D, world_target: Vector3, allowed_cells: Dictionary) -> bool:
	if unit == null or runtime_map.grid == null or allowed_cells.is_empty():
		return false
	register_unit(unit)
	var agent: Dictionary = registry.agent_for(_agents, unit)
	if agent.is_empty():
		return false
	if unit.has_method("prepare_navigation_order") \
	and not bool(unit.call("prepare_navigation_order", world_target, Vector3.INF, NavConstantsScript.MoveMode.FREE)):
		return false
	avoidance.reset_agent(agent)
	# Refinery d/p cells deliberately receive the harvester body. Its full
	# direction-independent rotation envelope would also cover adjacent solid
	# refinery cells and make the authored dock unreachable. Use capsule width
	# only inside this explicitly reserved corridor; ordinary buildings still
	# use the full nose/tail envelope.
	registry.set_agent_rotation_envelope(agent, false)
	var command_id := _next_command_id
	_next_command_id += 1
	agent["destination"] = world_target
	agent["reserved"] = true
	agent["claim_radius"] = 0.0
	agent["claim_center"] = world_target
	agent["command_id"] = command_id
	agent["mode"] = NavConstantsScript.MoveMode.FREE
	agent["group_speed"] = INF
	agent["hold"] = false
	agent["blocked_time"] = 0.0
	agent["reported_enemy"] = false
	agent["exit_point"] = Vector3.INF
	agent["yield_remaining"] = 0.0
	agent["yield_direction"] = Vector3.ZERO
	agent["route_lane_offset"] = 0.0
	agent["route_lane_min"] = 0.0
	agent["route_lane_max"] = 0.0
	agent["no_stop_destination"] = false
	agent["departure_access"] = false
	agent["allowed_cells"] = allowed_cells.duplicate()
	_route_agent(agent, unit.global_position, world_target)
	_agents[unit.get_instance_id()] = agent
	if unit.has_method("set_navigation_destination"):
		unit.call("set_navigation_destination", world_target)
	_command_log.append({
		"tick": _navigation_tick_index,
		"command_id": command_id,
		"mode": NavConstantsScript.MoveMode.FREE,
		"target": world_target,
		"agents": [agent["id"]],
		"slots": [world_target],
		"dock": true,
	})
	return bool(agent["direct_path"]) or not (agent["path"] as Array).is_empty()


func stop(unit: Node3D) -> void:
	var agent: Dictionary = registry.agent_for(_agents, unit)
	if agent.is_empty():
		return
	agent["path"] = [] as Array[Vector2i]
	agent["path_index"] = 0
	agent["active_order"] = false
	if unit.has_method("flight_clear_circles_order"):
		unit.call("flight_clear_circles_order")
	agent["destination"] = unit.global_position
	agent["direct_path"] = false
	agent["exit_point"] = Vector3.INF
	agent["yield_remaining"] = 0.0
	agent["yield_direction"] = Vector3.ZERO
	agent["no_stop_destination"] = false
	if bool(agent.get("departure_access", false)):
		agent["departure_access"] = false
		agent["allowed_cells"] = {}
	agent["reserved"] = true
	_agents[unit.get_instance_id()] = agent


## Dispatches route construction to the agent's movement domain.
func _route_agent(agent: Dictionary, from: Vector3, destination: Vector3) -> void:
	agent["domain"] = registry.domain_for(agent)
	if int(agent["domain"]) == NavAgentRegistryScript.Domain.AIR:
		air_navigation.route_agent(agent, from, destination)
	else:
		ground_navigation.route_agent(agent, from, destination)


func agent_debug(unit: Node3D) -> Dictionary:
	var agent := registry.agent_for(_agents, unit)
	if agent.is_empty():
		return {}
	return {
		"id": agent["id"],
		"radius": agent["radius"],
		"rotation_radius": agent["rotation_radius"],
		"terrain_radius": agent["terrain_radius"],
		"destination": agent["destination"],
		"command_id": agent["command_id"],
		"mode": agent["mode"],
		"group_speed": agent["group_speed"],
		"hold": agent["hold"],
		"no_stop_destination": agent["no_stop_destination"],
		"departure_access": agent["departure_access"],
		"blocked_time": agent["blocked_time"],
		"route_ready": bool(agent["direct_path"]) or not (agent["path"] as Array).is_empty() or (agent["exit_point"] as Vector3).is_finite(),
	}


## Shared arrival contract for navigation-driven gameplay state machines.
## Large authored vehicles stop farther from an exact point than small units;
## callers waiting for arrival must use the same tolerance as steering.
func arrival_tolerance(unit: Node3D) -> float:
	var agent := registry.agent_for(_agents, unit)
	var radius := float(agent.get("radius", 0.0))
	return maxf(_arrival_radius(unit), radius * 0.35)


func route_is_unreachable(unit: Node3D) -> bool:
	var agent := registry.agent_for(_agents, unit)
	return not agent.is_empty() and bool(agent.get("route_unreachable", false))


## Finds the closest stoppable ground position to an attack point that belongs
## to the unit's connected navigation region and still lies inside weapon
## range. Unlike command_move(), this searches the whole radius instead of
## testing one guessed perch on the direct unit-target line.
##
## `is_fireable_from` optionally rejects candidates the weapon could not
## actually shoot from, so a target on a plateau or behind a building is
## engaged from where the shot lands instead of from the foot of the obstacle.
func reachable_attack_position(
	unit: Node3D,
	world_target: Vector3,
	maximum_range: float,
	is_fireable_from := Callable()
	) -> Vector3:
	if unit == null or runtime_map.grid == null or maximum_range <= 0.0:
		return Vector3.INF
	var agent := registry.movement_probe_for(_agents, unit)
	if agent.is_empty():
		return Vector3.INF
	var grid = runtime_map.grid
	var target_cell: Vector2i = grid.world_to_grid(world_target)
	var cell_size: Vector2 = grid.cell_size()
	var minimum_cell_span := minf(cell_size.x, cell_size.y)
	if minimum_cell_span <= 0.0:
		return Vector3.INF
	var maximum_radius := ceili(maximum_range / minimum_cell_span)
	for radius in range(maximum_radius + 1):
		for offset in slot_allocator.ring_offsets(radius):
			var candidate := target_cell + offset
			if not grid.in_bounds(candidate):
				continue
			var position: Vector3 = grid.grid_to_world(candidate)
			var horizontal_offset := Vector2(
				position.x - world_target.x, position.z - world_target.z
			)
			if horizontal_offset.length() > maximum_range:
				continue
			if not _ground_target_is_legal(agent, position, false):
				continue
			if is_fireable_from.is_valid() \
			and not bool(is_fireable_from.call(position)):
				continue
			if _ground_target_is_reachable(unit, agent, position):
				return position
	return Vector3.INF


func command_log() -> Array[Dictionary]:
	return _command_log.duplicate(true)


func _physics_process(delta: float) -> void:
	if runtime_map.grid == null:
		return
	_navigation_accumulator += delta
	var tick_delta := 1.0 / NAVIGATION_TICK_RATE
	var ticks := 0
	while _navigation_accumulator >= tick_delta and ticks < MAX_CATCH_UP_TICKS:
		_navigation_accumulator -= tick_delta
		_navigation_tick(tick_delta)
		ticks += 1
	if _navigation_accumulator >= tick_delta:
		_navigation_accumulator = fmod(_navigation_accumulator, tick_delta)
	_blocker_refresh_remaining -= delta
	if _blocker_refresh_remaining <= 0.0:
		_blocker_refresh_remaining = BLOCKER_REFRESH_SECONDS
		_refresh_building_blockers()


func _navigation_tick(delta: float) -> void:
	_navigation_tick_index += 1
	registry.prune_agents(_agents)
	blocker_tracker.process_reroute_queue()
	var ordered := registry.ordered_agents(_agents)
	registry.update_domains(ordered)
	var ground_agents: Array[Dictionary] = []
	var air_agents: Array[Dictionary] = []
	for agent in ordered:
		if int(agent["domain"]) == NavAgentRegistryScript.Domain.AIR:
			air_agents.append(agent)
		else:
			ground_agents.append(agent)
	var claimants: Array[Dictionary] = []
	for agent in ground_agents:
		path_follower.release_departure_access_if_clear(agent)
		if not bool(agent["reserved"]):
			claimants.append(agent)
	# Closest to the target claims first: the unit already standing next to a
	# central block takes it, instead of a far unit crossing the whole pack.
	claimants.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		var a_offset: float = ((a["destination"] as Vector3) - (a["unit"] as Node3D).global_position).length()
		var b_offset: float = ((b["destination"] as Vector3) - (b["unit"] as Node3D).global_position).length()
		if is_equal_approx(a_offset, b_offset):
			return int(a["id"]) < int(b["id"])
		return a_offset < b_offset
	)
	for agent in claimants:
		slot_allocator.try_claim_slot(_agents, agent)
	slot_allocator.uncross_assignments(ground_agents)
	var ground_buckets := spatial_hash.build(ground_agents)
	ground_navigation.tick(delta, ground_agents, ground_buckets)
	if not air_agents.is_empty():
		var air_buckets := spatial_hash.build(air_agents)
		air_navigation.tick(delta, air_agents, air_buckets)
	_refresh_navigation_debug()


## Test-only shim: tests/navigation/run.gd and jitter_probe.gd call this by name. Not architecture.
func _desired_velocity(agent: Dictionary) -> Vector3:
	if int(agent.get("domain", NavAgentRegistryScript.Domain.GROUND)) == NavAgentRegistryScript.Domain.AIR:
		return air_navigation.desired_velocity(agent)
	return ground_navigation.desired_velocity(agent)


func _refresh_navigation_debug() -> void:
	if navigation_debug == null or not navigation_debug.is_inside_tree():
		return
	if not _debug_enabled:
		return
	var snapshots: Array[Dictionary] = []
	for value in _agents.values():
		var agent: Dictionary = value
		var unit: Node3D = agent["unit"]
		if not is_instance_valid(unit) or not &"is_selected" in unit \
		or not bool(unit.get("is_selected")):
			continue
		var height := unit.global_position.y + maxf(float(agent["radius"]) * 0.12, 0.18)
		var position := _debug_height(unit.global_position, height)
		var destination := _debug_height(agent["destination"], height)
		var route: Array[Vector3] = [position]
		var waypoint := Vector3.INF
		var exit_point: Vector3 = agent["exit_point"]
		if exit_point.is_finite():
			waypoint = _debug_height(exit_point, height)
			route.append(waypoint)
		elif bool(agent["direct_path"]):
			waypoint = destination
			route.append(destination)
		else:
			var path: Array = agent["path"]
			if not path.is_empty():
				var path_points: Array = ground_navigation.path_points_for(agent)
				var path_index := clampi(int(agent["path_index"]), 0, path_points.size() - 1)
				for index in range(path_index, path_points.size()):
					var point: Vector3 = _debug_height(path_points[index], height)
					if route.back().distance_squared_to(point) > 0.0001:
						route.append(point)
				if route.size() > 1:
					waypoint = route[1]
			if route.back().distance_squared_to(destination) > 0.0001:
				route.append(destination)
		var look_ahead: Vector3 = agent.get("steering_target", Vector3.INF)
		if look_ahead.is_finite():
			look_ahead = _debug_height(look_ahead, height)
		snapshots.append({
			"radius": agent["radius"],
			"route": route,
			"waypoint": waypoint,
			"look_ahead": look_ahead,
			"destination": destination,
		})
	navigation_debug.update_agents(snapshots)


static func _debug_height(point: Vector3, height: float) -> Vector3:
	return Vector3(point.x, height, point.z)


## Test-only shim: tests/navigation/run.gd calls this by name. Not architecture.
func _advanced_path_index(
		agent: Dictionary,
		path: Array,
		path_index: int,
		position: Vector3,
		speed := 0.0
	) -> int:
	return path_follower.advanced_path_index(agent, path, path_index, position, speed)


## Test-only shim: tests/navigation/run.gd calls this by name. Not architecture.
func _path_chord_is_clear(agent: Dictionary, from: Vector3, to: Vector3) -> bool:
	return path_follower.path_chord_is_clear(agent, from, to)


## Test-only shim: tests/navigation/run.gd calls this by name. Not architecture.
func _has_clear_line(from: Vector3, to: Vector3, agent: Dictionary) -> bool:
	return path_follower.has_clear_line(from, to, agent)


## Test-only shim: tests/navigation/run.gd calls this by name. Not architecture.
func _request_yield(unit: Node3D, direction: Vector3) -> void:
	ground_navigation.request_yield(unit, direction)


## Test-only shim: tests/navigation/run.gd calls this by name. Not architecture.
func _blocks_conflict(a: Vector2i, a_span: int, b: Vector2i, b_span: int) -> bool:
	return slot_allocator.blocks_conflict(a, a_span, b, b_span)


## Test-only shim: tests/navigation/run.gd calls this by name. Not architecture.
func _parking_anchor(point: Vector3, span: int) -> Vector2i:
	return slot_allocator.parking_anchor(point, span)


## Nearest free grid-aligned block center for the agent, avoiding every other
## agent's reserved parking block. Falls back to `point` when nothing is free.
func _ground_target_is_legal(agent: Dictionary, world_target: Vector3, allow_no_stop: bool) -> bool:
	var span: int = int(agent["footprint"])
	var anchor: Vector2i = slot_allocator.parking_anchor(world_target, span)
	return slot_allocator.block_passable(anchor, span, agent) if allow_no_stop \
		else slot_allocator.block_stoppable(anchor, span, agent)


func _ground_target_is_reachable(
		unit: Node3D, agent: Dictionary, world_target: Vector3, allow_no_stop := false
	) -> bool:
	var span: int = int(agent["footprint"])
	var anchor: Vector2i = slot_allocator.parking_anchor(world_target, span)
	return slot_allocator.anchor_reachable(
		anchor, agent, unit.global_position, allow_no_stop
	)


## Test-only shim: tests/navigation/run.gd calls this by name. Not architecture.
func _refresh_building_blockers() -> void:
	blocker_tracker.refresh_building_blockers()


## Test-only shim: tests/navigation/run.gd calls this by name. Not architecture.
func _replan_after_map_change() -> void:
	blocker_tracker.replan_after_map_change()


func _unit_cruise_speed(unit: Node3D) -> float:
	var value = unit.get("move_speed")
	return maxf(float(value), 0.0) if value != null else 0.0


func _arrival_radius(unit: Node3D) -> float:
	var value = unit.get("arrival_radius")
	return float(value) if value != null else 0.2


func _slowest_speed(units: Array[Node3D]) -> float:
	var speed := INF
	for unit in units:
		# Formation pace is a persistent cap. Capturing a mech's temporary
		# between-step speed here would pin the whole group to that low phase.
		speed = minf(speed, _unit_cruise_speed(unit))
	return speed


func _on_tree_node_added(node: Node) -> void:
	if not _owns_node(node):
		return
	if node.is_in_group("units") and node is Node3D:
		register_unit.call_deferred(node)
	elif node.is_in_group("buildings"):
		_refresh_building_blockers.call_deferred()


func _owns_node(node: Node) -> bool:
	var match_root := get_parent()
	return match_root != null and (node == match_root or match_root.is_ancestor_of(node))
