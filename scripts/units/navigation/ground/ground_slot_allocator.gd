class_name GroundSlotAllocator
extends RefCounted
## Parking-block selection: ring search for a free grid-aligned footprint
## block, formation/crowd aim-point spreading, route-lane assignment for
## groups sharing a corner, and slot-claim/uncross bookkeeping.
## Runtime-map and planner dependencies are injected explicitly; sibling
## modules are held weakly where the routing relationship is bidirectional.

const NavConstantsScript := preload("res://scripts/units/navigation/shared/nav_constants.gd")

var _runtime_map
var _planner
var _path_follower_ref: WeakRef
var _ground_navigation_ref: WeakRef
var _navigation_tick_index: Callable


func setup(
	runtime_map,
	planner,
	path_follower,
	ground_navigation,
	navigation_tick_index: Callable
	) -> void:
	_runtime_map = runtime_map
	_planner = planner
	_path_follower_ref = weakref(path_follower)
	_ground_navigation_ref = weakref(ground_navigation)
	_navigation_tick_index = navigation_tick_index


## Captures the group's initial lateral ordering once per player command. The
## value is deliberately geometric rather than agent-id based: units that
## already form an upper/lower row keep that row while the common A* centreline
## bends around terrain. Very scattered groups are clamped to their natural
## resting-pack width so a gather order does not create enormous detours.
func assign_route_lanes(agents: Dictionary, units: Array[Node3D], world_target: Vector3) -> void:
	if units.is_empty():
		return
	var centroid := Vector3.ZERO
	for unit in units:
		centroid += unit.global_position
	centroid /= float(units.size())
	var travel := world_target - centroid
	travel.y = 0.0
	if units.size() <= 1 or travel.length_squared() <= 0.0001:
		for unit in units:
			var agent: Dictionary = agents[unit.get_instance_id()]
			agent["route_lane_offset"] = 0.0
			agent["route_lane_min"] = 0.0
			agent["route_lane_max"] = 0.0
		return
	var lateral := travel.normalized().cross(Vector3.UP).normalized()
	var cell: Vector2 = _runtime_map.grid.cell_size()
	var lane_limit := ceilf(sqrt(float(units.size()))) * 0.5 \
		* float(largest_footprint(agents, units) + NavConstantsScript.PARKING_GAP_CELLS) * maxf(cell.x, cell.y)
	var entries: Array[Dictionary] = []
	for unit in units:
		var offset := unit.global_position - centroid
		offset.y = 0.0
		var agent: Dictionary = agents[unit.get_instance_id()]
		entries.append({
			"unit": unit,
			"raw": clampf(offset.dot(lateral), -lane_limit, lane_limit),
			"radius": float(agent["radius"]),
			"id": int(agent["id"]),
		})
	entries.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		if is_equal_approx(float(a["raw"]), float(b["raw"])):
			return int(a["id"]) < int(b["id"])
		return float(a["raw"]) < float(b["raw"])
	)
	# Units already in the same longitudinal file have essentially identical
	# lateral coordinates and should keep one lane. Distinct files are expanded
	# only when their authored spacing is narrower than the collision field.
	var clusters: Array[Dictionary] = []
	for entry in entries:
		if clusters.is_empty():
			clusters.append({
				"entries": [entry], "raw_sum": float(entry["raw"]),
				"raw_max": float(entry["raw"]), "radius": float(entry["radius"]),
			})
			continue
		var cluster: Dictionary = clusters.back()
		var same_lane_threshold := minf(float(cluster["radius"]), float(entry["radius"])) * 0.35
		if float(entry["raw"]) - float(cluster["raw_max"]) <= same_lane_threshold:
			(cluster["entries"] as Array).append(entry)
			cluster["raw_sum"] = float(cluster["raw_sum"]) + float(entry["raw"])
			cluster["raw_max"] = float(entry["raw"])
			cluster["radius"] = maxf(float(cluster["radius"]), float(entry["radius"]))
		else:
			clusters.append({
				"entries": [entry], "raw_sum": float(entry["raw"]),
				"raw_max": float(entry["raw"]), "radius": float(entry["radius"]),
			})
	var previous_lane := -INF
	var previous_radius := 0.0
	for cluster in clusters:
		var cluster_entries: Array = cluster["entries"]
		var raw_center := float(cluster["raw_sum"]) / float(cluster_entries.size())
		var lane := raw_center
		if previous_lane > -INF:
			var comfort := minf(previous_radius, float(cluster["radius"])) \
				* NavConstantsScript.ROUTE_LANE_COMFORT_RADIUS_FACTOR
			lane = maxf(lane, previous_lane + previous_radius + float(cluster["radius"]) + comfort)
		cluster["raw_center"] = raw_center
		cluster["lane"] = lane
		previous_lane = lane
		previous_radius = float(cluster["radius"])
	# Expanding from the low side alone would translate the whole formation.
	# Recenter the packed lanes around the midpoint of their original span.
	var raw_midpoint := (float(clusters.front()["raw_center"]) + float(clusters.back()["raw_center"])) * 0.5
	var lane_midpoint := (float(clusters.front()["lane"]) + float(clusters.back()["lane"])) * 0.5
	var recenter := raw_midpoint - lane_midpoint
	var offsets := {}
	var lane_min := INF
	var lane_max := -INF
	for cluster in clusters:
		var lane := float(cluster["lane"]) + recenter
		for entry in cluster["entries"]:
			offsets[(entry["unit"] as Node3D).get_instance_id()] = lane
		lane_min = minf(lane_min, lane)
		lane_max = maxf(lane_max, lane)
	for unit in units:
		var agent: Dictionary = agents[unit.get_instance_id()]
		agent["route_lane_offset"] = float(offsets[unit.get_instance_id()])
		agent["route_lane_min"] = lane_min
		agent["route_lane_max"] = lane_max


func assign_slots(agents: Dictionary, units: Array[Node3D], world_target: Vector3, mode: int) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	var occupied: Array[Dictionary] = []
	var spacing := largest_footprint(agents, units) + NavConstantsScript.PARKING_GAP_CELLS
	var allow_no_stop: bool = _runtime_map.is_no_stop(_runtime_map.grid.world_to_grid(world_target))
	for index in units.size():
		var unit := units[index]
		var agent: Dictionary = agents[unit.get_instance_id()]
		var span := int(agent["footprint"])
		var preferred := parking_anchor(world_target, span)
		if mode == NavConstantsScript.MoveMode.FORMATION:
			preferred += formation_offset(index, units.size(), float(spacing))
		else:
			preferred += crowd_offset(index) * spacing
		var anchor := claim_passable_anchor(preferred, agent, occupied, unit.global_position) \
			if allow_no_stop else find_slot(preferred, agent, occupied)
		var position: Vector3 = block_center(anchor, span) if anchor.x >= 0 else unit.global_position
		position.y = world_target.y
		var assignment := {
			"unit": unit,
			"agent_id": agent["id"],
			"slot_id": index,
			"position": position,
			"available": anchor.x >= 0,
			"no_stop_destination": anchor.x >= 0 and not block_stoppable(anchor, span, agent),
		}
		result.append(assignment)
		if anchor.x >= 0:
			occupied.append({"anchor": anchor, "span": span})
	return result


## FREE moves do not pre-plan parking slots: a pre-assigned interior slot
## belongs to whoever happens to arrive last, and the crowd has to fight itself
## to deliver that unit. Each unit aims at the target translated by its own
## offset inside the pack (clamped to the resting pack radius), so the group
## moves as a shape instead of funnelling through one point, then claims the
## best free block on approach (try_claim_slot), packing in arrival order.
func shared_target_assignments(agents: Dictionary, units: Array[Node3D], world_target: Vector3) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	var occupied: Array[Dictionary] = []
	var centroid := Vector3.ZERO
	for unit in units:
		centroid += unit.global_position
	centroid /= float(units.size())
	var cell: Vector2 = _runtime_map.grid.cell_size()
	var pack_radius := ceilf(sqrt(float(units.size()))) * 0.5 \
		* float(largest_footprint(agents, units) + NavConstantsScript.PARKING_GAP_CELLS) * maxf(cell.x, cell.y)
	var spread := 0.0
	for unit in units:
		spread = maxf(spread, Vector2(unit.global_position.x - centroid.x, unit.global_position.z - centroid.z).length())
	# A compact pack is being MOVED: keep its shape, claims stay at each aim
	# point. A group scattered wider than its resting size is being GATHERED:
	# claims run center-out from the target so the pack fills up tight.
	var gather := spread > pack_radius * 1.5
	var allow_no_stop: bool = _runtime_map.is_no_stop(_runtime_map.grid.world_to_grid(world_target))
	for index in units.size():
		var unit := units[index]
		var agent: Dictionary = agents[unit.get_instance_id()]
		var span := int(agent["footprint"])
		var offset := unit.global_position - centroid
		offset.y = 0.0
		var aim := world_target + offset.limit_length(pack_radius)
		# When the aim lies inside a building footprint, approach it radially from
		# this unit's current side. A ring-first search otherwise picks a corner
		# before the centered cell on the same side of a rectangular building.
		var preferred := parking_anchor(aim, span)
		var anchor := claim_passable_anchor(preferred, agent, occupied, unit.global_position) \
			if allow_no_stop else approach_anchor(preferred, agent, unit.global_position)
		# Never fall back to the unvalidated spread aim: it may be a free cell
		# inside a disconnected island. Staying put is the safe fallback when
		# the bounded slot search cannot find a reachable candidate.
		var position := block_center(anchor, span) if anchor.x >= 0 else unit.global_position
		position.y = world_target.y
		var no_stop_destination := anchor.x >= 0 and not block_stoppable(anchor, span, agent)
		result.append({
			"unit": unit,
			"agent_id": agent["id"],
			"slot_id": index,
			"position": position,
			"available": anchor.x >= 0,
			"claim_center": world_target if gather else position,
			"no_stop_destination": no_stop_destination,
		})
		if allow_no_stop and anchor.x >= 0:
			occupied.append({"anchor": anchor, "span": span})
	return result


## The moment a FREE-move unit gets near the shared target it claims a parking
## block: the most central free one, tie-broken toward its own approach side so
## claims do not cross the crowd.
func try_claim_slot(agents: Dictionary, agent: Dictionary) -> void:
	var unit: Node3D = agent["unit"]
	if bool(agent["hold"]) or (agent["exit_point"] as Vector3).is_finite():
		return
	var destination: Vector3 = agent["destination"]
	var offset := destination - unit.global_position
	offset.y = 0.0
	if offset.length() > float(agent["claim_radius"]):
		return
	var span := int(agent["footprint"])
	# The search is centered on the shared command target, not the unit's own
	# aim point: the pack packs center-out and does not settle into a ring.
	var anchor := claim_anchor(parking_anchor(agent["claim_center"], span), agent, reserved_blocks(agents, agent), unit.global_position)
	if anchor.x < 0:
		return
	agent["reserved"] = true
	var parked := block_center(anchor, span)
	parked.y = destination.y
	agent["destination"] = parked
	_ground_navigation_ref.get_ref().route_agent(agent, unit.global_position, parked)
	if unit.has_method("set_navigation_destination"):
		unit.call("set_navigation_destination", parked)


## Uncrosses parking assignments within a command: when two units would each
## travel further to their own blocks than to each other's, they trade blocks
## instead of trying to push their bodies past one another. Crossed pairs are
## what makes a nudged pack fight itself indefinitely.
func uncross_assignments(ordered_agents: Array[Dictionary]) -> void:
	var groups := {}
	for agent in ordered_agents:
		if int(agent["command_id"]) <= 0 or not bool(agent["reserved"]) or bool(agent["hold"]) \
		or bool(agent.get("no_stop_destination", false)):
			continue
		if (agent["exit_point"] as Vector3).is_finite():
			continue
		# Only units still moving inside the arrival zone take part: crossings
		# out in the open resolve themselves by steering, and a unit already
		# parked on its block must not be dragged out by a trade.
		var unit: Node3D = agent["unit"]
		var offset: Vector3 = (agent["destination"] as Vector3) - unit.global_position
		offset.y = 0.0
		if offset.length() > float(agent["claim_radius"]):
			continue
		if offset.length() <= maxf(_arrival_radius(unit), float(agent["radius"]) * 0.35):
			continue
		# A cooldown after each trade stops marginal swaps from flip-flopping
		# every tick while two units move in near-symmetry.
		if int(_navigation_tick_index.call()) - int(agent["swap_tick"]) < NavConstantsScript.SWAP_COOLDOWN_TICKS:
			continue
		var key := "%d:%d" % [int(agent["command_id"]), int(agent["footprint"])]
		if not groups.has(key):
			groups[key] = []
		groups[key].append(agent)
	for key in groups:
		var group: Array = groups[key]
		for a_index in group.size():
			for b_index in range(a_index + 1, group.size()):
				var a: Dictionary = group[a_index]
				var b: Dictionary = group[b_index]
				var a_unit: Node3D = a["unit"]
				var b_unit: Node3D = b["unit"]
				var a_destination: Vector3 = a["destination"]
				var b_destination: Vector3 = b["destination"]
				var current := a_unit.global_position.distance_to(a_destination) \
					+ b_unit.global_position.distance_to(b_destination)
				var swapped := a_unit.global_position.distance_to(b_destination) \
					+ b_unit.global_position.distance_to(a_destination)
				if swapped + 0.05 < current:
					a["destination"] = b_destination
					b["destination"] = a_destination
					a["swap_tick"] = int(_navigation_tick_index.call())
					b["swap_tick"] = int(_navigation_tick_index.call())
					_ground_navigation_ref.get_ref().route_agent(
						a, a_unit.global_position, b_destination
					)
					_ground_navigation_ref.get_ref().route_agent(
						b, b_unit.global_position, a_destination
					)
					if a_unit.has_method("set_navigation_destination"):
						a_unit.call("set_navigation_destination", b_destination)
					if b_unit.has_method("set_navigation_destination"):
						b_unit.call("set_navigation_destination", a_destination)


## Parking blocks already promised to other agents: reserved destinations only,
## so shared aim points of units that have not claimed yet do not count.
func reserved_blocks(agents: Dictionary, agent: Dictionary) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for key in agents:
		var other: Dictionary = agents[key]
		if int(other["id"]) == int(agent["id"]) or not bool(other["reserved"]):
			continue
		var other_span := int(other["footprint"])
		result.append({"anchor": parking_anchor(other["destination"], other_span), "span": other_span})
	return result


func claim_radius_for(agents: Dictionary, units: Array[Node3D]) -> float:
	var cell: Vector2 = _runtime_map.grid.cell_size()
	var pitch := float(largest_footprint(agents, units) + NavConstantsScript.PARKING_GAP_CELLS)
	var crowd := ceilf(sqrt(float(units.size()))) * 0.5 * pitch
	return (crowd + 2.0) * maxf(cell.x, cell.y)


func find_slot(preferred: Vector2i, agent: Dictionary, occupied: Array[Dictionary]) -> Vector2i:
	var unit: Node3D = agent["unit"]
	return claim_anchor(preferred, agent, occupied, unit.global_position)


## Initial FREE-move aim selection. Walks outward from a blocked target toward
## the unit, so approaching a building does not send every unit to whichever
## corner happens to occur on the first valid Chebyshev ring.
func approach_anchor(preferred: Vector2i, agent: Dictionary, from: Vector3) -> Vector2i:
	var span := int(agent["footprint"])
	var from_anchor := parking_anchor(from, span)
	var delta := from_anchor - preferred
	var length := maxi(absi(delta.x), absi(delta.y))
	if length > 0:
		var limit := mini(length, NavConstantsScript.SLOT_SEARCH_RADIUS)
		for distance in range(0, limit + 1):
			var weight := float(distance) / float(length)
			var offset := Vector2i(
				roundi(float(delta.x) * weight),
				roundi(float(delta.y) * weight)
			)
			var candidate := preferred + offset
			if block_stoppable(candidate, span, agent) \
			and anchor_reachable(candidate, agent, from):
				return candidate
	return claim_anchor(preferred, agent, [], from)


## Ring search for a free grid-aligned footprint block: every cell of the
## span x span block must be stoppable and the block may not overlap a block in
## `occupied` ({anchor, span} entries). Inner rings keep priority; ties within
## a ring resolve toward `from`.
func claim_anchor(preferred: Vector2i, agent: Dictionary, occupied: Array[Dictionary], from: Vector3) -> Vector2i:
	var span := int(agent["footprint"])
	for radius in range(0, NavConstantsScript.SLOT_SEARCH_RADIUS + 1):
		var best := Vector2i(-1, -1)
		var best_distance := INF
		for offset in ring_offsets(radius):
			var anchor := preferred + offset
			if not block_stoppable(anchor, span, agent):
				continue
			if not anchor_reachable(anchor, agent, from):
				continue
			var blocked := false
			for other in occupied:
				if blocks_conflict(anchor, span, other["anchor"], int(other["span"])):
					blocked = true
					break
			if blocked:
				continue
			var distance := from.distance_to(block_center(anchor, span))
			if distance < best_distance:
				best_distance = distance
				best = anchor
		if best.x >= 0:
			return best
	return Vector2i(-1, -1)


## No-stop destinations need the same nearest, non-overlapping block search as
## ordinary parking, but accept any traversable block for their final stop.
func claim_passable_anchor(
		preferred: Vector2i,
		agent: Dictionary,
		occupied: Array[Dictionary],
		from: Vector3
	) -> Vector2i:
	var span := int(agent["footprint"])
	for radius in range(0, NavConstantsScript.SLOT_SEARCH_RADIUS + 1):
		var best := Vector2i(-1, -1)
		var best_distance := INF
		for offset in ring_offsets(radius):
			var anchor := preferred + offset
			if not block_passable(anchor, span, agent):
				continue
			if not anchor_reachable(anchor, agent, from, true):
				continue
			var occupied_block := false
			for other in occupied:
				if blocks_conflict(anchor, span, other["anchor"], int(other["span"])):
					occupied_block = true
					break
			if occupied_block:
				continue
			var distance := from.distance_to(block_center(anchor, span))
			if distance < best_distance:
				best_distance = distance
				best = anchor
		if best.x >= 0:
			return best
	return Vector2i(-1, -1)


## Passability alone is insufficient for an automatically distributed target:
## an otherwise free block may belong to a nearby enclosed navigation island.
## Keep every generated aim/parking block in the querying unit's connected
## component, just like the exact player-click validation does.
func anchor_reachable(
		anchor: Vector2i, agent: Dictionary, from: Vector3, allow_no_stop := false
	) -> bool:
	var span: int = int(agent["footprint"])
	var target_center := block_center(anchor, span)
	var target_cell: Vector2i = _runtime_map.grid.world_to_grid(target_center)
	var stoppable_no_stop_cells := {target_cell: true} if allow_no_stop else {}
	return _planner.is_reachable(
		_runtime_map.grid.world_to_grid(from), target_cell,
		int(agent["pass_mask"]), int(agent["clearance"]), int(agent["terrain_mask"]),
		stoppable_no_stop_cells
	)


func block_passable(anchor: Vector2i, span: int, agent: Dictionary) -> bool:
	for y in span:
		for x in span:
			if not _path_follower_ref.get_ref().agent_cell_passable(
				agent, anchor + Vector2i(x, y), 0
			):
				return false
	return body_fits(anchor, span, agent)


func block_stoppable(anchor: Vector2i, span: int, agent: Dictionary) -> bool:
	for y in span:
		for x in span:
			if not _path_follower_ref.get_ref().agent_cell_stoppable(
				agent, anchor + Vector2i(x, y), 0
			):
				return false
	return body_fits(anchor, span, agent)


## Whole-cell clearance is the routing grid's shape, not the unit's: expanding
## every footprint cell by the rotation envelope keeps a parked body a further
## sqrt(2) off any diagonal or stair-stepped edge, and a long chassis further
## still along an axis it never turns on while parked. The footprint cells above
## are therefore checked bare (clearance 0) and the real spacing comes from the
## authored body disc at the block centre — the same envelope local steering
## already keeps clear of terrain while driving.
func body_fits(anchor: Vector2i, span: int, agent: Dictionary) -> bool:
	return _runtime_map.body_fits(
		block_center(anchor, span),
		int(agent["pass_mask"]),
		float(agent.get("radius", 0.0)),
		int(agent["terrain_mask"])
	)


## Two parking blocks conflict when fewer than PARKING_GAP_CELLS free cells
## separate them (in either axis), not only on actual overlap.
func blocks_conflict(a: Vector2i, a_span: int, b: Vector2i, b_span: int) -> bool:
	return a.x < b.x + b_span + NavConstantsScript.PARKING_GAP_CELLS and b.x < a.x + a_span + NavConstantsScript.PARKING_GAP_CELLS \
		and a.y < b.y + b_span + NavConstantsScript.PARKING_GAP_CELLS and b.y < a.y + a_span + NavConstantsScript.PARKING_GAP_CELLS


static func _arrival_radius(unit: Node3D) -> float:
	var value = unit.get("arrival_radius")
	return float(value) if value != null else 0.2


## World center of a span x span cell block anchored at its lowest cell. For
## even spans the center sits on the shared cell corner.
func block_center(anchor: Vector2i, span: int) -> Vector3:
	var center: Vector3 = _runtime_map.grid.grid_to_world(anchor)
	var cell: Vector2 = _runtime_map.grid.cell_size()
	var shift := float(span - 1) * 0.5
	return center + Vector3(cell.x * shift, 0.0, cell.y * shift)


## Anchor cell of the block whose center lies nearest to `point`.
func parking_anchor(point: Vector3, span: int) -> Vector2i:
	var cell: Vector2 = _runtime_map.grid.cell_size()
	var shift := float(span - 1) * 0.5
	return _runtime_map.grid.world_to_grid(point - Vector3(cell.x * shift, 0.0, cell.y * shift))


## Nearest reachable grid-aligned block center for the agent, avoiding every
## other agent's reserved parking block. Falls back to the current position
## when nothing is free.
func snapped_parking(agents: Dictionary, agent: Dictionary, point: Vector3) -> Vector3:
	var span := int(agent["footprint"])
	var unit: Node3D = agent["unit"]
	var anchor := claim_anchor(
		parking_anchor(point, span), agent, reserved_blocks(agents, agent),
		unit.global_position
	)
	if anchor.x < 0:
		return unit.global_position
	var parked := block_center(anchor, span)
	parked.y = point.y
	return parked


func ring_offsets(radius: int) -> Array[Vector2i]:
	if radius == 0:
		return [Vector2i.ZERO]
	var result: Array[Vector2i] = []
	for x in range(-radius, radius + 1):
		result.append(Vector2i(x, -radius))
		result.append(Vector2i(x, radius))
	for y in range(-radius + 1, radius):
		result.append(Vector2i(-radius, y))
		result.append(Vector2i(radius, y))
	return result


func crowd_offset(index: int) -> Vector2i:
	if index == 0:
		return Vector2i.ZERO
	var ring := int(ceil((sqrt(float(index + 1)) - 1.0) * 0.5))
	var side := ring * 2
	var first := (side - 1) * (side - 1)
	var position := index - first
	if position < side:
		return Vector2i(-ring + position, -ring)
	position -= side
	if position < side:
		return Vector2i(ring, -ring + position)
	position -= side
	if position < side:
		return Vector2i(ring - position, ring)
	return Vector2i(-ring, ring - (position - side))


func formation_offset(index: int, count: int, spacing: float) -> Vector2i:
	var columns := int(ceil(sqrt(float(count))))
	var row := index / columns
	var column := index % columns
	return Vector2i(
		int(round((float(column) - float(columns - 1) * 0.5) * spacing)),
		int(round(float(row) * spacing))
	)


func largest_footprint(agents: Dictionary, units: Array[Node3D]) -> int:
	var span := 1
	for unit in units:
		var agent: Dictionary = agents[unit.get_instance_id()]
		span = maxi(span, int(agent["footprint"]))
	return span
