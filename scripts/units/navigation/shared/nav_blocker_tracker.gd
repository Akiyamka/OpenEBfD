class_name NavBlockerTracker
extends RefCounted

const OccupyGridScript := preload("res://scripts/buildings/occupy_grid.gd")
## Building-blocker bookkeeping: scans placed buildings into the navigation
## grid's blocked/no-stop cell sets, diffs the resulting cell changes against
## each commanded agent's stored route, and drains the resulting dirty-agent
## queue through a budgeted per-tick reroute so a single building change never
## bursts every commanded agent's A* in one frame.

const NavAgentRegistryScript := preload("res://scripts/units/navigation/shared/nav_agent_registry.gd")
const NavConstantsScript := preload("res://scripts/units/navigation/shared/nav_constants.gd")
const BuildingFootprintScript := preload("res://scripts/buildings/building_footprint.gd")
const BuildingDefinitionCatalogScript := preload("res://scripts/buildings/building_definition_catalog.gd")

static var _building_definition_catalog := BuildingDefinitionCatalogScript.shared()

var _facade: Node
var _runtime_map
var _reroute_queue: Array = []
var _agents: Dictionary
var _registry
var _slot_allocator
var _path_follower
var _ground_navigation
var _owns_node: Callable


func setup(
	facade: Node,
	runtime_map,
	agents: Dictionary,
	registry,
	slot_allocator,
	path_follower,
	ground_navigation,
	owns_node: Callable
	) -> void:
	_facade = facade
	_runtime_map = runtime_map
	_agents = agents
	_registry = registry
	_slot_allocator = slot_allocator
	_path_follower = path_follower
	_ground_navigation = ground_navigation
	_owns_node = owns_node


func refresh_building_blockers() -> void:
	if not _facade.is_inside_tree() or _runtime_map.grid == null:
		return
	var blocked := {}
	var no_stop := {}
	# "sim_buildings", not "buildings": this rebuilds the blocked-cell grid
	# from UnitNavigationSystem.sim_tick() (periodically) and setup() (once),
	# both simulation-side call sites. A building "buildings" lists but
	# "sim_buildings" does not (post C6b, not yet admitted) must not yet
	# block a cell the tick's own movement can still route through.
	for node in _facade.get_tree().get_nodes_in_group("sim_buildings"):
		var building := node as Node3D
		if building == null or not _owns_node.call(building):
			continue
		var config = building.get("building_definition") as Resource \
			if "building_definition" in building else null
		if config == null:
			var config_id := StringName(str(building.get("config_id")))
			config = _building_definition_catalog.definition(config_id)
		if config == null:
			continue
		var rows: Array = config.occupy_rows
		var footprint: Dictionary = BuildingFootprintScript.nav_cells_by_marker(
			building, rows, _runtime_map.grid, NavConstantsScript.OCCUPY_CELL_SPAN
		)
		for cell in footprint:
			# Skirts, doors and pads are transit space, but ordinary orders must
			# not park there. The refinery grants its reserved harvester a local
			# d/p stopping exception; authored building body cells stay solid.
			var marker := String(footprint[cell]).to_lower()
			var target := no_stop if marker in ["s", "d", "p"] else blocked
			target[cell] = true
	if _runtime_map.replace_blocked_cells(blocked, no_stop):
		replan_after_map_change()


## Blocker refreshes run independently of navigation ticks, so an agent's unit
## may have been freed since the last regular pruning pass. Only identifies
## agents whose route the change might have invalidated and queues them for a
## budgeted reroute (`process_reroute_queue`) — replanning every commanded
## agent unconditionally here is what used to turn a single building change
## into an O(N) full-A* burst.
func replan_after_map_change() -> void:
	_registry.prune_agents(_agents)
	var changed_indices: PackedInt32Array = _runtime_map.changed_cells()
	if changed_indices.is_empty():
		return
	var changed_lookup := {}
	for index in changed_indices:
		changed_lookup[index] = true
	for key in _agents.keys():
		var agent: Dictionary = _agents[key]
		if int(agent["command_id"]) <= 0:
			continue
		# Air agents never route through the grid at all (see
		# air/air_navigation.gd) — a building-blocker change can never
		# invalidate their route.
		if _registry.domain_for(agent) == NavAgentRegistryScript.Domain.AIR:
			continue
		if agent_route_intersects(agent, changed_lookup) and not _reroute_queue.has(key):
			_reroute_queue.append(key)


## True when a building-blocker change might invalidate `agent`'s current
## route: its destination block, or (for an A*-routed agent) any raw cell
## along its stored corridor, or (for a direct-path agent, which has no
## corridor) its straight line no longer being clear, lies in/crosses
## `changed_lookup`. The corridor check looks at the whole corridor rather
## than only the remaining cells ahead of the follower's path index — the raw
## corridor's indices do not line up with the simplified waypoint list's
## `path_index` cursor, and reconciling that would need restructuring the path
## representation, which is out of scope for this pass. The corridor is
## bounded in length and this only runs on the rare tick a blocker actually
## changes, so scanning all of it (or re-checking one direct line) is still
## cheap next to the previous unconditional full replan of every commanded
## agent.
func agent_route_intersects(agent: Dictionary, changed_lookup: Dictionary) -> bool:
	var span := int(agent["footprint"])
	var destination: Vector3 = agent["destination"]
	var destination_anchor: Vector2i = _slot_allocator.parking_anchor(destination, span)
	for y in span:
		for x in span:
			var index: int = _runtime_map.grid.cell_index(destination_anchor + Vector2i(x, y))
			if index >= 0 and changed_lookup.has(index):
				return true
	if bool(agent["direct_path"]):
		# A direct-path agent has no stored corridor to diff against (it never
		# went through the planner), so the only way to tell whether the
		# blocker change invalidated its straight line is to re-run the exact
		# predicate that approved it in the first place.
		var unit: Node3D = agent["unit"]
		# simulation_position(), not global_position, since slice R4: this
		# re-runs the exact predicate GroundNavigation.route_agent() used to
		# approve the straight line, and that call has been handed a store
		# position since R3. Asking the node here would let the two disagree
		# about the same line. `unit` stays a bare Node3D, so the call is
		# duck-typed and a test double has to answer it.
		var unit_position: Vector3 = unit.simulation_position()
		return not _path_follower.has_clear_line(unit_position, destination, agent)
	var corridor: PackedInt32Array = agent.get("corridor", PackedInt32Array())
	for index in corridor:
		if changed_lookup.has(index):
			return true
	return false


## Drains up to REROUTE_BUDGET_PER_TICK agents from the facade's reroute queue
## each navigation tick, so a large simultaneous blocker change spreads its A*
## re-runs over several ticks instead of stalling one frame. Queued agents
## keep following their existing (possibly slightly stale, but still mostly
## valid) path until their turn comes.
func process_reroute_queue() -> void:
	if _reroute_queue.is_empty():
		return
	var changed_by_command := {}
	var budget := NavConstantsScript.REROUTE_BUDGET_PER_TICK
	while budget > 0 and not _reroute_queue.is_empty():
		var key = _reroute_queue.pop_front()
		budget -= 1
		if not _agents.has(key):
			continue
		var agent: Dictionary = _agents[key]
		if int(agent["command_id"]) <= 0:
			continue
		var destination: Vector3 = agent["destination"]
		var span := int(agent["footprint"])
		var destination_anchor: Vector2i = _slot_allocator.parking_anchor(destination, span)
		var destination_stoppable: bool = _slot_allocator.block_stoppable(destination_anchor, span, agent)
		if bool(agent.get("no_stop_destination", false)) and destination_stoppable:
			agent["no_stop_destination"] = false
		if not destination_stoppable \
		and not (bool(agent.get("no_stop_destination", false)) and _slot_allocator.block_passable(destination_anchor, span, agent)):
			var replacement: Vector2i = _slot_allocator.find_slot(
				destination_anchor, agent, _slot_allocator.reserved_blocks(_agents, agent)
			)
			if replacement.x >= 0:
				var height := destination.y
				destination = _slot_allocator.block_center(replacement, span)
				destination.y = height
				agent["destination"] = destination
				agent["no_stop_destination"] = false
				agent["original_destination"] = destination
				var command_id := int(agent["command_id"])
				if not changed_by_command.has(command_id):
					changed_by_command[command_id] = []
				changed_by_command[command_id].append({
					"unit": agent["unit"], "agent_id": agent["id"], "slot_id": -1,
					"position": destination, "available": true,
				})
		# simulation_position(), not global_position, since slice R4: a reroute
		# plans this agent's new route from where the simulation says it
		# stands, exactly as command_move() and command_dock() now do.
		var unit: Node3D = agent["unit"]
		var unit_position: Vector3 = unit.simulation_position()
		_ground_navigation.route_agent(agent, unit_position, destination)
		_agents[key] = agent
	for command_id in changed_by_command:
		_facade.destination_slots_assigned.emit(command_id, changed_by_command[command_id])


func empty_occupy_marker(marker: String) -> bool:
	return OccupyGridScript.is_empty_marker(marker)
