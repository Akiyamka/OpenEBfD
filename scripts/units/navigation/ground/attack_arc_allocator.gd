class_name AttackArcAllocator
extends RefCounted
## Angular firing slots around one attack target.
##
## An attack order reaches each unit individually (UnitCommandController loops
## the selection and calls `command_attack` per entity, and the pursuit that
## follows issues a one-unit `command_move`), so nothing used to spread a group
## out: every shooter ran the same perch search, converged on the same cell, and
## the first arrivals stopped on the max-range ring and walled the rest out of
## range entirely. Handing each unit its own bearing around the target turns
## that queue into an arc -- which is also what stops a rear rank from standing
## on a front rank's muzzle line.
##
## Deliberately pure geometry: it reads unit positions and agent radii and
## returns one bearing per unit. Turning a bearing into a body position (range
## band, terrain legality, reachability, friendly occupancy) is
## `UnitNavigationSystem.reachable_firing_position`'s job, and each unit does
## that for itself with its own weapon range -- so a mixed-range group settles
## into concentric arcs rather than one ring at the shortest range.

## The order asks for a half-circle at most. A full englobement reads as the
## group walking around a target that is usually shooting back, and the far side
## of the ring is where units cross each other's lines.
const MAXIMUM_ARC_SPAN := PI
## Two units do not fan 90 degrees apart just because there is room. Beyond this
## the arc stops looking like a firing line and starts looking like a pincer.
const MAXIMUM_SLOT_STEP := PI / 6.0
## Slot pitch as a multiple of the widest body in the group: two radii of actual
## body plus this much clear space, matching the intent of PARKING_GAP_CELLS.
const SLOT_PITCH_RADIUS_FACTOR := 3.0
## Only reached for a unit with no registered navigation agent (a test double,
## or one asked about before registration). Matches the registry's own floor.
const DEFAULT_BODY_RADIUS := 0.35


## `engagement_radius` is the ring the pitch is measured on -- pass the group's
## shortest preferred weapon range, so spacing is adequate on the tightest arc
## any member will actually stand on.
##
## Returns { unit instance id: horizontal unit vector pointing from the target
## toward that unit's slot }. Units with no registered agent still get a slot;
## only the pitch degrades to a default body size.
func assign_arcs(
		agents: Dictionary,
		units: Array[Node3D],
		world_target: Vector3,
		engagement_radius: float
	) -> Dictionary:
	var result := {}
	if units.is_empty():
		return result
	# simulation_position(), not global_position, since slice R4: which bearing
	# each shooter is handed is a simulation decision taken on the command's own
	# tick, so it must read the store rather than the node's mirror. Cached into
	# `positions` here and reused by the bearing loop below rather than read
	# twice per unit -- the accessor resolves the owning Match by walking each
	# node's ancestors (MatchLookup._live_match) where a field read was free,
	# and nothing between the two loops moves anybody. Every `unit` here stays a
	# bare Node3D, so the call is duck-typed exactly as the rest of navigation's
	# is and a test double standing in for a Unit has to answer it.
	var positions: Array[Vector3] = []
	var centroid := Vector3.ZERO
	for unit in units:
		var unit_position: Vector3 = unit.simulation_position()
		positions.append(unit_position)
		centroid += unit_position
	centroid /= float(units.size())
	var base := centroid - world_target
	base.y = 0.0
	# A group standing exactly on its target has no approach side to preserve;
	# any bearing is as good as any other, so pick a stable one.
	base = base.normalized() if base.length_squared() > 0.0001 else Vector3.BACK
	var base_angle := atan2(base.z, base.x)

	# Slots are handed out in the order the units already stand in around the
	# target, not by agent id: anything else makes the two flanks trade places
	# and cross the whole crowd to reach their slots.
	var entries: Array[Dictionary] = []
	var widest_radius := 0.0
	for index in units.size():
		var unit: Node3D = units[index]
		var agent: Dictionary = agents.get(unit.get_instance_id(), {})
		widest_radius = maxf(widest_radius, float(agent.get("radius", DEFAULT_BODY_RADIUS)))
		var offset := positions[index] - world_target
		offset.y = 0.0
		var bearing := atan2(offset.z, offset.x) if offset.length_squared() > 0.0001 \
			else base_angle
		entries.append({
			"unit": unit,
			# Signed offset from the approach bearing, so sorting runs flank to
			# flank across the group's own front rather than wrapping at +/-PI.
			"offset": angle_difference(base_angle, bearing),
			"id": int(agent.get("id", unit.get_instance_id())),
		})
	entries.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		if is_equal_approx(float(a["offset"]), float(b["offset"])):
			return int(a["id"]) < int(b["id"])
		return float(a["offset"]) < float(b["offset"])
	)

	var count := entries.size()
	var pitch := maxf(widest_radius, DEFAULT_BODY_RADIUS) * SLOT_PITCH_RADIUS_FACTOR
	# Guard the division: a target inside the group's own footprint would
	# otherwise produce a step of many radians from an engagement radius of
	# nearly zero.
	var step := minf(pitch / maxf(engagement_radius, pitch), MAXIMUM_SLOT_STEP)
	if count > 1:
		# Past this many units the arc is full. Compressing rather than adding a
		# second ring is deliberate: `reachable_firing_position` rejects perches
		# already occupied by a firing neighbour, so the overflow settles onto
		# its own outer arc by itself instead of being planned into one here.
		step = minf(step, MAXIMUM_ARC_SPAN / float(count - 1))
	for index in count:
		var angle := base_angle + (float(index) - float(count - 1) * 0.5) * step
		var unit: Node3D = entries[index]["unit"]
		result[unit.get_instance_id()] = Vector3(cos(angle), 0.0, sin(angle))
	return result
