class_name NavAgentRegistry
extends RefCounted

const EntityQueryScript := preload("res://scripts/world/entity_query.gd")
const NavConstantsScript := preload("res://scripts/units/navigation/shared/nav_constants.gd")
const MapNavigationGridScript := preload("res://scripts/world/map/map_navigation_grid.gd")
## Owns navigation agent creation/removal, movement-profile derivation, and the
## per-tick pruning/ordering of the agent set. `_agents` itself remains a
## Dictionary owned by the facade (`UnitNavigationSystem._agents`); GDScript
## Dictionaries are reference types, so this module receives it as a parameter
## on every call instead of holding its own copy.

## The tick's own iteration source for units (Unit.SIM_UNITS_GROUP, slice
## C6a). Repeated as a literal rather than preloaded from unit.gd on purpose:
## this module is handed duck-typed Node3Ds, not Unit instances -- every
## navigation suite registers a FakeUnit -- so depending on unit.gd's whole
## preload chain to name one string would be a dependency the registry
## otherwise does not have. UnitNavigationSystem.setup() reads the same
## literal for the same reason.
const SIM_UNITS_GROUP := &"sim_units"

## GROUND also covers a flying unit that is currently grounded/landed: it acts
## as a stationary hold-obstacle for ground avoidance until it takes off again
## (see `domain_for`), never as a routed ground agent.
enum Domain { GROUND, AIR }

var _facade: Node
var _runtime_map
var _planner
var _avoidance
var _next_agent_id := 1


func setup(facade: Node, runtime_map, planner, avoidance) -> void:
	_facade = facade
	_runtime_map = runtime_map
	_planner = planner
	_avoidance = avoidance
	_next_agent_id = 1


## Returns the agent id `unit` now holds, or 0 when it holds none.
##
## The SIM_UNITS_GROUP refusal below is slice C6c's gate, and it lives here
## rather than in UnitNavigationSystem.register_unit() for two reasons. The
## facade's register_unit() is this function's only caller, so the two
## placements cover the same population; and this is already where refusals
## of this class live -- navigation_is_suspended() next door refuses a unit
## whose transform a transport anchor owns, which is the same sentence about
## a different owner.
##
## What it buys: command_move(), command_dock(), assign_attack_arcs() and
## resume_unit() all call register_unit() unconditionally, so "navigation
## never drives a unit the tick does not simulate" holds for all four without
## any of them checking. A unit whose admission the queue has not yet drained
## (see Unit._ready() and scripts/match/sim_admission_queue.gd) simply gets no
## agent until it has, and UnitNavigationSystem's pending list re-tries it on
## the next tick rather than dropping it.
##
## Ahead of the agents.has(key) fast path deliberately: nothing ever removes a
## unit from SIM_UNITS_GROUP -- despawn frees the node instead, and
## prune_agents() collects the agent -- so an already-registered unit always
## passes this check, and putting the gate second would only make the refusal
## depend on registration history.
func register_unit(agents: Dictionary, unit: Node3D, debug_enabled: bool) -> int:
	if unit == null:
		return 0
	if unit.has_method("navigation_is_suspended") and bool(unit.call("navigation_is_suspended")):
		return 0
	if not unit.is_in_group(SIM_UNITS_GROUP):
		return 0
	var key := unit.get_instance_id()
	if agents.has(key):
		return int(agents[key]["id"])
	var profile := profile_for(unit)
	# simulation_position(), not global_position, since slice R4. The three
	# fields seeded from it below -- `destination`, `steering_target` and
	# `claim_center` -- are read back by the tick every tick afterwards
	# (GroundNavigation.desired_velocity() measures arrival against
	# `destination`; GroundSlotAllocator's claim search centres on
	# `claim_center`), so seeding them from the node would put a mirror value
	# into simulation state and let every later store read inherit it.
	#
	# This is also the one site in R4 where the accessor's fallback is
	# load-bearing rather than merely tolerated. A unit reaches here before
	# anything has written its position to SimEntityState in real paths --
	# Unit._register_entity_id() pushes owner_player_id and not position, so
	# has_position() is false until that unit's first set_simulation_position()
	# -- and simulation_position() answers from the node in exactly that case.
	# Seeding from the node directly would be indistinguishable *today* and
	# wrong the moment registration ever follows a store write, which is
	# already the ordinary case for a unit that registers after match start.
	var unit_position: Vector3 = unit.simulation_position()
	var agent := {
		"id": _next_agent_id,
		"unit": unit,
		"radius": profile["radius"],
		"rotation_radius": profile["rotation_radius"],
		"terrain_radius": profile["rotation_radius"],
		"pass_mask": profile["pass_mask"],
		"terrain_mask": profile["terrain_mask"],
		"clearance": profile["clearance"],
		"body_clearance": profile["body_clearance"],
		"rotation_clearance": profile["clearance"],
		"footprint": profile["footprint"],
		"path": [] as Array[Vector2i],
		"path_index": 0,
		# Raw A* cell indices for the current route (before waypoint
		# simplification), used only to test whether a building-blocker
		# change actually crosses this agent's route (see
		# `_agent_route_intersects`). Empty while on a direct line.
		"corridor": PackedInt32Array(),
		"path_points": [] as Array[Vector3],
		"destination": unit_position,
		# Distinct from destination: Circles aircraft continue along an idle
		# orbit after this becomes false.
		"active_order": false,
		"command_id": 0,
		"mode": NavConstantsScript.MoveMode.FREE,
		"group_speed": INF,
		"hold": false,
		# Standing on a firing position under an explicit attack order. Weaker
		# than `hold`: the body must not be shoved off the spot mid-clip (which
		# restarts the fire animation and, once it walks back, loops), but a
		# friendly genuinely stuck behind the firing line may still ask it to
		# step aside -- see `request_yield`, which `hold` refuses outright.
		"firing_anchor": false,
		"blocked_time": 0.0,
		"reported_enemy": false,
		"avoidance_direction": Vector3.ZERO,
		"steering_turn_in_place": false,
		# ORCA backend: last tick's actually-achieved velocity (used, not
		# `v_pref`, when building this tick's reciprocal avoidance lines —
		# see `ground/orca_avoidance.gd`).
		"orca_velocity": Vector3.ZERO,
		"steering_target": unit_position,
		# Units issued one group order keep their initial cross-route ordering.
		# The compact A* paths may share a corner cell, but the runtime follower
		# treats it as a gate and gives each body a parallel lane through it.
		"route_lane_offset": 0.0,
		"route_lane_min": 0.0,
		"route_lane_max": 0.0,
		"yield_direction": Vector3.ZERO,
		"yield_remaining": 0.0,
		"direct_path": false,
		"exit_point": Vector3.INF,
		"reserved": true,
		"claim_radius": 0.0,
		"claim_center": unit_position,
		"swap_tick": -1000,
		# An explicit ordinary order may deliberately end and remain on
		# traversable no-stop space.
		"no_stop_destination": false,
		# A harvester leaving a refinery temporarily keeps access to that
		# refinery's d/p cells. The exception is dropped as soon as its complete
		# footprint reaches ordinary stoppable ground.
		"departure_access": false,
		# Per-order exception used only while a harvester enters its reserved
		# refinery pad. Ordinary commands always clear it.
		"allowed_cells": {},
	}
	agent["domain"] = domain_for(agent)
	agents[key] = agent
	_next_agent_id += 1
	# A flying unit never routes through the ground A*/avoidance grid profile
	# (airborne: its own straight-line air pipeline; grounded: a stationary
	# hold-obstacle that never plans a route) — prewarming one for it would
	# just be a wasted grid bake.
	if int(profile["pass_mask"]) != MapNavigationGridScript.PASS_AIR:
		_planner.prewarm(int(profile["pass_mask"]), int(profile["clearance"]), int(profile["terrain_mask"]))
		_avoidance.prewarm(int(profile["pass_mask"]), int(profile["terrain_mask"]))
	unit.set_meta(&"navigation_agent_id", agent["id"])
	if unit.has_method("set_navigation_managed"):
		unit.call("set_navigation_managed", true)
	if unit.has_method("set_navigation_controller"):
		unit.call("set_navigation_controller", _facade)
	if unit.has_method("set_navigation_debug_visible"):
		unit.call("set_navigation_debug_visible", debug_enabled)
	return int(agent["id"])


func unregister_unit(agents: Dictionary, unit: Node3D) -> void:
	if unit == null:
		return
	if unit.has_method("set_navigation_debug_visible"):
		unit.call("set_navigation_debug_visible", false)
	if unit.has_method("set_navigation_managed"):
		unit.call("set_navigation_managed", false)
	agents.erase(unit.get_instance_id())


func profile_for(unit: Node3D) -> Dictionary:
	var config = unit.get("unit_definition")
	var infantry := bool(config.infantry) if config != null else false
	var can_fly := bool(config.can_fly) if config != null else false
	var size := float(config.size) if config != null else 1.0
	var radius := maxf(0.35, size * 0.42)
	if unit.has_method("navigation_collision_radius"):
		radius = float(unit.call("navigation_collision_radius", radius))
	var rotation_radius := radius
	if unit.has_method("navigation_rotation_radius"):
		rotation_radius = maxf(
			radius, float(unit.call("navigation_rotation_radius", rotation_radius))
		)
	var cell_size: Vector2 = _runtime_map.grid.cell_size()
	var body_clearance := maxi(
		0,
		int(ceil(radius / maxf(minf(cell_size.x, cell_size.y), 0.001))) - 1
	)
	var clearance := maxi(
		0,
		int(ceil(rotation_radius / maxf(minf(cell_size.x, cell_size.y), 0.001))) - 1
	)
	var pass_mask := MapNavigationGridScript.PASS_AIR if can_fly else (MapNavigationGridScript.PASS_INFANTRY if infantry else MapNavigationGridScript.PASS_VEHICLE)
	# A flying unit's authored Terrain list constrains only where it may land,
	# never where it may fly — leave it unrestricted here so routing never
	# detours around terrain types (e.g. InfantryRock) that only matter to
	# ground movement classes.
	var terrain_mask_value := 0 if can_fly else terrain_mask(config.terrain_ids if config != null else [])
	# `size` is the side of the unit's square footprint in navigation cells;
	# destinations are always the center of a free size x size cell block.
	var footprint := maxi(1, roundi(size))
	return {
		"radius": radius,
		"rotation_radius": rotation_radius,
		"body_clearance": body_clearance,
		"clearance": clearance,
		"pass_mask": pass_mask,
		"terrain_mask": terrain_mask_value,
		"footprint": footprint,
	}


func terrain_mask(names: Array) -> int:
	var result := 0
	for value in names:
		match String(value).to_lower():
			"sand": result |= 1 << MapNavigationGridScript.TERRAIN_SAND
			"rock": result |= 1 << MapNavigationGridScript.TERRAIN_ROCK
			"cliff": result |= 1 << MapNavigationGridScript.TERRAIN_CLIFF
			"nbrock", "nonbuildrock": result |= 1 << MapNavigationGridScript.TERRAIN_NONBUILDROCK
			"infrock", "infantryrock": result |= 1 << MapNavigationGridScript.TERRAIN_INFANTRYROCK
			"dustbowl": result |= 1 << MapNavigationGridScript.TERRAIN_DUSTBOWL
			"ramp": result |= 1 << MapNavigationGridScript.TERRAIN_RAMP
	return result


func movement_probe_for(agents: Dictionary, unit: Node3D) -> Dictionary:
	var registered := agent_for(agents, unit)
	if not registered.is_empty():
		return {
			"clearance": registered["rotation_clearance"],
			"radius": registered["radius"],
			"pass_mask": registered["pass_mask"],
			"terrain_mask": registered["terrain_mask"],
			"footprint": registered["footprint"],
			"allowed_cells": {},
		}
	var profile := profile_for(unit)
	return {
		"clearance": profile["clearance"],
		"radius": profile["radius"],
		"pass_mask": profile["pass_mask"],
		"terrain_mask": profile["terrain_mask"],
		"footprint": profile["footprint"],
		"allowed_cells": {},
	}


func prune_agents(agents: Dictionary) -> void:
	for key in agents.keys():
		var unit = agents[key]["unit"]
		if not EntityQueryScript.is_live(unit):
			agents.erase(key)


func agent_for(agents: Dictionary, unit: Node3D) -> Dictionary:
	if unit == null:
		return {}
	return agents.get(unit.get_instance_id(), {})


func ordered_agents(agents: Dictionary) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for value in agents.values():
		result.append(value)
	result.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return int(a["id"]) < int(b["id"]))
	return result


func set_agent_rotation_envelope(agent: Dictionary, active: bool) -> void:
	agent["terrain_radius"] = agent["rotation_radius"] if active else agent["radius"]
	agent["clearance"] = agent["rotation_clearance"] \
		if active else agent["body_clearance"]


## AIR only while a flying agent is actually taking off/cruising/hovering/
## landing; a landed (or non-flying) unit is GROUND, regardless of pass mask —
## it sits still and participates in ground avoidance as a hold-obstacle
## instead of being routed by either pipeline. Recomputed every tick: takeoff/
## landing transitions only last ~1.5s, so this is cheap enough to just always
## reflect the unit's live flight phase instead of caching it across an order.
func domain_for(agent: Dictionary) -> int:
	if int(agent["pass_mask"]) != MapNavigationGridScript.PASS_AIR:
		return Domain.GROUND
	var unit: Node3D = agent.get("unit")
	if unit != null and unit.has_method("flight_is_airborne_phase") \
	and not bool(unit.call("flight_is_airborne_phase")):
		return Domain.GROUND
	return Domain.AIR


func update_domains(agents_list: Array[Dictionary]) -> void:
	for agent in agents_list:
		agent["domain"] = domain_for(agent)
