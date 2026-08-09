class_name OrcaAvoidance
extends RefCounted
## Optimal Reciprocal Collision Avoidance (RVO2-style) neighbour/terrain
## avoidance backend for `resolve_velocity`.
##
## All geometry below is solved in the ground plane as Vector2(x, z); Vector3
## in/out at the edges only. Static terrain is modelled as a zero-velocity
## "agent" (an inscribed-circle obstacle disc, per `SteeringStabilizer.
## terrain_context`) so the same half-plane construction covers both terrain
## and neighbour avoidance.
##
## Contract: `resolve_velocity(agent, desired, delta, nearby, resolved) ->
## {velocity, enemies, friends}` — identical to the candidate-sampling
## backend it replaces, so tests exercising the facade's `avoidance` field
## directly need no changes.

const EPSILON := 0.00001
const TAU := 0.75
const TAU_OBST := 0.4
const MAX_NEIGHBORS := 8
const MAX_OBST_LINES := 10
const OBSTACLE_SECTOR_ANGLE := PI / 3.0
const RESPONSIBILITY_MUTUAL := 0.5
const RESPONSIBILITY_AGAINST_IDLE := 0.25
const RESPONSIBILITY_HARD := 1.0
const COURSE_DAMPING_SHARE := 0.35
const SQUEEZE_RESULT_FACTOR := 1.0
const SQUEEZE_COOLDOWN_TICKS := 6
## Combined-radius scale for the direct full-speed squeeze branch's clear-path
## check against other agents. Below 1.0 so the bounded elastic overlap
## `separation_velocity` already relies on for an ordinary crowd squeeze still
## reads as clear, while a friendly genuinely at contact still drives the
## fraction toward zero instead of being rammed at full speed.
const SQUEEZE_CONTACT_RADIUS_FACTOR := 0.8

var runtime_map = null
var stabilizer = null


func setup(source_runtime_map, source_stabilizer) -> void:
	runtime_map = source_runtime_map
	stabilizer = source_stabilizer


func resolve_velocity(
		agent: Dictionary,
		desired: Vector3,
		delta: float,
		nearby: Array,
		_resolved: Dictionary
	) -> Dictionary:
	agent["_v_pref"] = desired
	var unit: Node3D = agent["unit"]
	var own_pos := _flat(unit.global_position)
	var max_speed := desired.length()
	var v_pref := _flat(desired)
	var route_direction := v_pref.normalized()

	var hard_lines: Array[Dictionary] = []
	var soft_lines: Array[Dictionary] = []
	var enemies: Array[Node3D] = []
	var friends: Array[Node3D] = []

	var own_velocity: Vector2 = _flat(agent.get("orca_velocity", Vector3.ZERO))

	# Terrain: nearest boundary-ish obstacle discs, hard, full responsibility.
	# A straight or thick wall contributes many adjacent solid cells at
	# similar distance and near-identical direction; treating each as an
	# independent half-plane (even the nearest `MAX_OBST_LINES` of them) lets
	# their intersection become far more restrictive than the true continuous
	# boundary — e.g. a 1-wide corridor's north and south cells jointly ruling
	# out most of the along-corridor speed range, not just the cross-corridor
	# one. Keeping only the nearest cell per coarse angular sector collapses
	# that redundancy while a genuinely different-direction obstacle (a real
	# corner) still keeps its own sector and its own line.
	var terrain: Dictionary = stabilizer.terrain_context(agent, max_speed * TAU_OBST)
	if not bool(terrain.get("escape", false)):
		var combined := float(terrain["hard_radius"])
		var nearest_per_sector: Dictionary = {}
		for value in (terrain["obstacles"] as Array):
			var obstacle_pos := _flat(value as Vector3)
			var relative := obstacle_pos - own_pos
			var dist_sq := relative.length_squared()
			var sector := int(floor(relative.angle() / OBSTACLE_SECTOR_ANGLE))
			if not nearest_per_sector.has(sector) or dist_sq < float(nearest_per_sector[sector]["dist_sq"]):
				nearest_per_sector[sector] = {"position": relative, "dist_sq": dist_sq}
		var obstacle_candidates: Array = nearest_per_sector.values()
		obstacle_candidates.sort_custom(func(a, b): return float(a["dist_sq"]) < float(b["dist_sq"]))
		for index in mini(MAX_OBST_LINES, obstacle_candidates.size()):
			var relative: Vector2 = obstacle_candidates[index]["position"]
			var line := _velocity_obstacle_line(
				relative, own_velocity, Vector2.ZERO, combined, TAU_OBST, delta,
				RESPONSIBILITY_HARD, max_speed, true
			)
			hard_lines.append(line)

	# Neighbours: nearest MAX_NEIGHBORS others within reach, split hard/soft by
	# reciprocal responsibility (enemy/hold neighbours are hard; a moving
	# agent yields less to a merely-idle one, which gets nudged instead by the
	# unchanged elastic `separation_velocity` in the tick's apply phase).
	var neighbor_candidates: Array = []
	for other in nearby:
		var other_unit: Node3D = other["unit"]
		if other_unit == unit:
			continue
		var other_pos := _flat(other_unit.global_position)
		var relative := other_pos - own_pos
		var combined_radius := float(agent["radius"]) + float(other["radius"])
		var reach := combined_radius + max_speed * TAU
		var dist_sq := relative.length_squared()
		if dist_sq > reach * reach:
			continue
		neighbor_candidates.append({
			"other": other, "position": relative, "dist_sq": dist_sq, "radius": combined_radius
		})
	neighbor_candidates.sort_custom(func(a, b): return float(a["dist_sq"]) < float(b["dist_sq"]))

	var kept := 0
	for entry in neighbor_candidates:
		if kept >= MAX_NEIGHBORS:
			break
		kept += 1
		var other: Dictionary = entry["other"]
		var other_unit: Node3D = other["unit"]
		var relative: Vector2 = entry["position"]
		var combined_radius: float = entry["radius"]
		var are_enemies: bool = stabilizer._are_enemies(unit, other_unit)
		var other_hold := bool(other.get("hold", false))
		var other_moving := true
		if other.has("_v_pref"):
			other_moving = not (other["_v_pref"] as Vector3).is_zero_approx()
		var hard: bool = are_enemies or other_hold
		var responsibility := RESPONSIBILITY_HARD if hard \
			else (RESPONSIBILITY_MUTUAL if other_moving else RESPONSIBILITY_AGAINST_IDLE)
		var other_velocity: Vector2 = _flat(other.get("orca_velocity", Vector3.ZERO))
		var line := _velocity_obstacle_line(
			relative, own_velocity, other_velocity, combined_radius, TAU, delta,
			responsibility, max_speed
		)
		if hard:
			hard_lines.append(line)
		else:
			soft_lines.append(line)
		# A neighbour actively constrains this tick if the unconstrained
		# preferred velocity would violate its ORCA half-plane.
		if _violates(line, v_pref):
			if are_enemies:
				if not enemies.has(other_unit):
					enemies.append(other_unit)
			elif not friends.has(other_unit):
				friends.append(other_unit)

	var lines: Array[Dictionary] = []
	lines.append_array(hard_lines)
	lines.append_array(soft_lines)
	var num_hard := hard_lines.size()

	var result := Vector2.ZERO
	var fail_index = _linear_program_2(lines, max_speed, v_pref, false)
	if typeof(fail_index) == TYPE_DICTIONARY:
		result = fail_index["velocity"]
	else:
		result = _linear_program_3(lines, num_hard, int(fail_index), max_speed, v_pref)

	# A head-on meeting (a tight corridor with no room to sidestep, or several
	# agents converging reciprocally with none of them ever gaining ground)
	# can leave the fully reciprocal LP near-stalled without ever failing
	# outright: every side symmetrically yields to the others' soft lines and
	# converges on a valid but non-advancing point — this includes an agent
	# left oscillating sideways with nonzero *speed* but negligible *route
	# progress* (a large crowd squeezing through one choke point can produce
	# exactly that, and it never trips the facade's own near-zero-velocity
	# `blocked_time`). Re-solving against hard lines only (ignoring soft/
	# friend lines) lets the body advance into soft contact instead, where the
	# unchanged elastic `separation_velocity` finishes the pass in the tick's
	# apply phase. Gated on route progress already having been low on a prior
	# call (mirrors the old candidate pass's squeeze re-evaluation, which only
	# ran once a unit was stuck): an open first encounter with room for a
	# genuine lateral detour resolves in the soft LP itself and must keep that
	# detour instead of this straight-through fallback, which — comparing
	# only forward progress — would otherwise always look more attractive
	# than a lateral solution. Only taken when it makes strictly more route
	# progress than the reciprocal solution, so it never overrides a
	# genuinely better detour once blocked.
	# `blocked_time` alone flickers off the instant a squeeze attempt lands one
	# decent tick — even mid-crowd, where the very next tick's fully
	# reciprocal solution (now legitimately eligible again since the agent
	# "wasn't blocked") relapses into the same near-stalled point, alternating
	# forever without ever compounding into real progress. A short cooldown
	# keeps the fallback available for a few ticks after the last blocked one,
	# so a genuine squeeze-through gets more than a single attempt.
	# A single tick above `delta` is required (not `> 0.0`) because
	# `_apply_resolved_velocity`'s displacement check (`ground_navigation.gd`)
	# reports exactly one blocked tick on an agent's very first move after a
	# fresh order or reset, before any achieved-velocity history exists — a
	# one-tick blip, not a real stall, and it must not itself open six ticks
	# of squeeze fallback for an otherwise freely-moving agent.
	var was_stalled := float(agent.get("blocked_time", 0.0)) > delta \
		or int(agent.get("_squeeze_cooldown", 0)) > 0
	if was_stalled:
		# The ORCA cone itself is what throttles speed this deep into a tight
		# passage (a smaller reaction window near two close hard lines caps the
		# safe speed well below cruise, same as it would with genuinely more
		# room) — reusing it here would produce a "safe" squeeze speed that
		# elastic `separation_velocity`'s fixed cap (`SEPARATION_MAX_SPEED_
		# FACTOR`) can simply out-push every tick, the same deadlock as before.
		# The old candidate pass's squeeze re-evaluation instead used a genuine
		# swept-disc terrain check (ignoring the other agent, not a velocity-
		# obstacle cone), which is unthrottled by the *reaction-time* margin —
		# only by whether the straight route line is physically clear this
		# tick. Try full speed along the route first; only fall back to the
		# (slower, throttled) hard-lines LP solution when that swept check
		# finds a genuine wall in the way.
		var direct_displacement := Vector3(route_direction.x, 0.0, route_direction.y) * max_speed * delta
		var squeeze_velocity: Vector2
		if not route_direction.is_zero_approx() and stabilizer.motion_is_passable(agent, direct_displacement):
			# `motion_is_passable` only clears static terrain; a stationary
			# (idle/held) neighbour must also block this branch, or it rams
			# straight through at full speed instead of yielding to the
			# reciprocal solution. A MOVING neighbour is deliberately exempt:
			# this direct branch is what lets two reciprocally moving agents
			# actually squeeze past each other at cruise speed in a tight
			# corridor, relying on the bounded elastic `separation_velocity`
			# (tick's apply phase) to keep that temporary overlap non-
			# penetrating -- restricting it here too would throttle every
			# ordinary moving-crowd squeeze back down to the same deadlock
			# this fallback exists to escape.
			var stationary_nearby: Array = []
			for other in nearby:
				if other["unit"] == unit:
					continue
				var other_moving := true
				if other.has("_v_pref"):
					other_moving = not (other["_v_pref"] as Vector3).is_zero_approx()
				if not other_moving:
					stationary_nearby.append(other)
			# Scale by how much of the direct sweep is clear of every
			# stationary neighbour at SQUEEZE_CONTACT_RADIUS_FACTOR, so one
			# sitting at genuine contact drives this toward zero. The
			# strictly-greater dot-product comparison below then keeps the
			# safer reciprocal solution instead of ramming through it.
			var unit_fraction: float = stabilizer.unit_sweep_fraction(
				agent, direct_displacement, stationary_nearby, SQUEEZE_CONTACT_RADIUS_FACTOR
			)
			squeeze_velocity = route_direction * max_speed * unit_fraction
		else:
			var hard_only = _linear_program_2(hard_lines, max_speed, v_pref, false)
			squeeze_velocity = (hard_only["velocity"] as Vector2) * SQUEEZE_RESULT_FACTOR \
				if typeof(hard_only) == TYPE_DICTIONARY else Vector2.ZERO
		if squeeze_velocity.dot(route_direction) > result.dot(route_direction):
			result = squeeze_velocity

	# Course damping: independently-nearest-10 discretized terrain lines can
	# rotate a few degrees tick to tick as the agent's own position shifts
	# (a new cell becomes the nearest one), which a rules-turn-rate chassis
	# renders as a visible wag along an otherwise smooth wall. Follow the
	# previous *call's* direction a bounded share of the way toward this
	# tick's optimum instead of snapping to it outright — but only when that
	# previous direction was still heading roughly the same way as this
	# tick's route (a fresh route/order has no continuity to preserve, and
	# blending toward an unrelated stale heading is how this went wrong the
	# first time: `resolve_velocity` is also called per-heading-sample by
	# direct tests reusing one `agent` dict across unrelated headings). The
	# damped course is checked against every hard line before use, so it
	# never crosses a boundary the raw solution avoided.
	if not hard_lines.is_empty() and result.length() > 0.01:
		var previous_direction: Vector3 = agent.get("avoidance_direction", Vector3.ZERO)
		if not previous_direction.is_zero_approx() \
		and _flat(previous_direction).normalized().dot(route_direction) > 0.0:
			var target_direction := Vector3(result.x, 0.0, result.y).normalized()
			var course_gap := previous_direction.normalized().signed_angle_to(target_direction, Vector3.UP)
			if absf(course_gap) > 0.005:
				var damped_direction := (previous_direction.normalized() as Vector3) \
					.rotated(Vector3.UP, course_gap * COURSE_DAMPING_SHARE)
				var damped := Vector2(damped_direction.x, damped_direction.z) * result.length()
				var blocked := damped.dot(route_direction) < 0.0
				if not blocked:
					for line in hard_lines:
						if _violates(line, damped):
							blocked = true
							break
				if not blocked:
					result = damped

	# Avoidance may slow the route down or slide sideways, but it must not
	# reinterpret a stable route target as a retreat. A genuine interior-escape
	# start (`terrain.escape`) already skips terrain lines above, so it never
	# needs this exception; a real reverse belongs to a new route/yield
	# decision, which has the persistence a per-tick velocity does not.
	if not result.is_zero_approx() and not route_direction.is_zero_approx() \
	and result.normalized().dot(route_direction) < 0.0:
		result = Vector2.ZERO

	agent["avoidance_direction"] = Vector3(result.x, 0.0, result.y).normalized() \
		if result.length() > 0.01 else Vector3.ZERO
	agent["_squeeze_cooldown"] = SQUEEZE_COOLDOWN_TICKS if was_stalled \
		else maxi(0, int(agent.get("_squeeze_cooldown", 0)) - 1)
	var velocity := Vector3(result.x, 0.0, result.y)
	agent["orca_velocity"] = velocity
	return {"velocity": velocity, "enemies": enemies, "friends": friends}


## Standard RVO2 velocity-obstacle half-plane for one neighbour (or a static
## obstacle when `other_velocity` is zero and `responsibility` is 1.0).
## `relative` is the other's position minus ours; `own_velocity`/
## `other_velocity` are last tick's actual velocities (not this tick's
## preference — reciprocity depends on what neighbours actually did).
static func _velocity_obstacle_line(
		relative: Vector2,
		own_velocity: Vector2,
		other_velocity: Vector2,
		combined_radius: float,
		tau: float,
		delta: float,
		responsibility: float,
		max_speed: float,
		clamp_to_boundary: bool = false
	) -> Dictionary:
	var relative_velocity := own_velocity - other_velocity
	var dist_sq := relative.length_squared()
	var combined_sq := combined_radius * combined_radius
	# Terrain is modelled as many independent overlapping obstacle discs (one
	# per nearby solid cell) rather than one continuous boundary. The
	# instantaneous-separation branch below is meant for a single genuine
	# penetration (two colliding bodies); applied independently to several
	# mutually overlapping static discs at once, it produces near-arbitrary
	# emergency directions per disc whose half-planes can jointly rule out
	# every velocity, even where the true continuous boundary leaves an
	# obviously open path. Callers building terrain lines pass
	# `clamp_to_boundary` to always take the ordinary cone/leg branch instead
	# — right at the boundary that degenerates to a tangent line through the
	# agent's own envelope edge, which is exactly the smooth "slide along the
	# wall" limit this discretization is meant to approximate.
	if clamp_to_boundary:
		dist_sq = maxf(dist_sq, combined_sq * 1.0001)
	var direction: Vector2
	var u: Vector2
	if dist_sq > combined_sq:
		var w := relative_velocity - relative / tau
		var w_length_sq := w.length_squared()
		var dot1 := w.dot(relative)
		if dot1 < 0.0 and dot1 * dot1 > combined_sq * w_length_sq:
			var w_length := sqrt(w_length_sq)
			var unit_w := w / w_length
			direction = Vector2(unit_w.y, -unit_w.x)
			u = (combined_radius / tau - w_length) * unit_w
		else:
			var leg := sqrt(maxf(dist_sq - combined_sq, 0.0))
			if relative.cross(w) > 0.0:
				direction = Vector2(
					relative.x * leg - relative.y * combined_radius,
					relative.x * combined_radius + relative.y * leg
				) / dist_sq
			else:
				direction = -Vector2(
					relative.x * leg + relative.y * combined_radius,
					-relative.x * combined_radius + relative.y * leg
				) / dist_sq
			var dot2 := relative_velocity.dot(direction)
			u = dot2 * direction - relative_velocity
	else:
		var inv_time_step := 1.0 / maxf(delta, 0.001)
		var w := relative_velocity - relative * inv_time_step
		var w_length := w.length()
		var unit_w := w / w_length if w_length > EPSILON else Vector2.RIGHT
		direction = Vector2(unit_w.y, -unit_w.x)
		u = (combined_radius * inv_time_step - w_length) * unit_w
	var point := own_velocity + u * responsibility
	# A deep interpenetration (agent already well inside an obstacle/neighbour
	# envelope) demands an instantaneous correction of `combined_radius /
	# delta`, easily dwarfing the agent's own cruise speed. Left unclamped,
	# that pushes `point` outside the max-speed disc entirely, which makes
	# `_linear_program_1` provably infeasible for this line forever (a
	# permanent stall, not a transient one — the geometry recomputes
	# identically every tick while the agent cannot move). Since the disc
	# radius is a hard cap on reachable velocity regardless, clamping the
	# line's anchor to just inside it keeps the line's *direction* (the
	# actual escape heading) intact while guaranteeing the LP always has a
	# feasible point on this line to fall back to.
	var max_reach := maxf(max_speed, EPSILON) - EPSILON
	if point.length_squared() > max_reach * max_reach:
		point = point.normalized() * max_reach
	return {"point": point, "direction": direction}


static func _violates(line: Dictionary, velocity: Vector2) -> bool:
	var direction: Vector2 = line["direction"]
	var point: Vector2 = line["point"]
	return direction.cross(point - velocity) > 0.0


## Ports RVO2's linearProgram1: the point on `lines[line_no]` closest to
## `opt_velocity` (or furthest along it, if `direction_opt`) that still
## satisfies every earlier line and the max-speed disc. Returns `{velocity}`
## on success, `null` when the disc/earlier lines leave nothing on this line.
static func _linear_program_1(
		lines: Array[Dictionary],
		line_no: int,
		radius: float,
		opt_velocity: Vector2,
		direction_opt: bool
	):
	var line: Dictionary = lines[line_no]
	var point: Vector2 = line["point"]
	var direction: Vector2 = line["direction"]
	var dot_product := point.dot(direction)
	var discriminant := dot_product * dot_product + radius * radius - point.length_squared()
	if discriminant < 0.0:
		return null
	var sqrt_discriminant := sqrt(discriminant)
	var t_left := -dot_product - sqrt_discriminant
	var t_right := -dot_product + sqrt_discriminant
	for index in line_no:
		var other: Dictionary = lines[index]
		var denominator := direction.cross(other["direction"])
		var numerator := (other["direction"] as Vector2).cross(point - (other["point"] as Vector2))
		if absf(denominator) <= EPSILON:
			if numerator < 0.0:
				return null
			continue
		var t := numerator / denominator
		if denominator >= 0.0:
			t_right = minf(t_right, t)
		else:
			t_left = maxf(t_left, t)
		if t_left > t_right:
			return null
	var t: float
	if direction_opt:
		t = t_right if opt_velocity.dot(direction) > 0.0 else t_left
	else:
		t = clampf(direction.dot(opt_velocity - point), t_left, t_right)
	return {"velocity": point + t * direction}


## Ports RVO2's linearProgram2. Returns `{velocity}` when every line in
## `lines` is satisfied; otherwise the (int) index of the first line that
## could not be satisfied (the caller falls back to `_linear_program_3`).
static func _linear_program_2(
		lines: Array[Dictionary],
		radius: float,
		opt_velocity: Vector2,
		direction_opt: bool
	):
	var result: Vector2
	if direction_opt:
		result = opt_velocity * radius
	elif opt_velocity.length_squared() > radius * radius:
		result = opt_velocity.normalized() * radius
	else:
		result = opt_velocity
	for index in lines.size():
		var line: Dictionary = lines[index]
		if (line["direction"] as Vector2).cross((line["point"] as Vector2) - result) > 0.0:
			var candidate = _linear_program_1(lines, index, radius, opt_velocity, direction_opt)
			if candidate == null:
				return index
			result = candidate["velocity"]
	return {"velocity": result}


## Ports RVO2's linearProgram3: once `_linear_program_2` fails on
## `lines[begin_line]`, re-solves velocity as close as possible to that line
## while treating every line before `begin_line` as an unconditional
## constraint (their intersections with the failing/later soft lines become
## new projected lines) — the hard/terrain lines stay enforced; only mutual
## soft/friendly conflicts are relaxed.
## `_opt_velocity` is intentionally unused here and retained for signature
## parity with RVO2's linearProgram3.
static func _linear_program_3(
		lines: Array[Dictionary],
		num_hard: int,
		begin_line: int,
		radius: float,
		_opt_velocity: Vector2
	) -> Vector2:
	var result := Vector2.ZERO
	var distance := 0.0
	for index in range(begin_line, lines.size()):
		var line: Dictionary = lines[index]
		if (line["direction"] as Vector2).cross((line["point"] as Vector2) - result) > distance:
			var proj_lines: Array[Dictionary] = []
			for hard_index in num_hard:
				proj_lines.append(lines[hard_index])
			for other_index in range(num_hard, index):
				var other: Dictionary = lines[other_index]
				var denominator := (line["direction"] as Vector2).cross(other["direction"])
				var proj_point: Vector2
				if absf(denominator) <= EPSILON:
					if (line["direction"] as Vector2).dot(other["direction"]) > 0.0:
						continue
					proj_point = 0.5 * ((line["point"] as Vector2) + (other["point"] as Vector2))
				else:
					var t := (other["direction"] as Vector2).cross(
						(line["point"] as Vector2) - (other["point"] as Vector2)
					) / denominator
					proj_point = (line["point"] as Vector2) + t * (line["direction"] as Vector2)
				var proj_direction := ((other["direction"] as Vector2) - (line["direction"] as Vector2)).normalized()
				proj_lines.append({"point": proj_point, "direction": proj_direction})
			var perpendicular := Vector2(-(line["direction"] as Vector2).y, (line["direction"] as Vector2).x)
			var solved = _linear_program_2(proj_lines, radius, perpendicular, true)
			# `_linear_program_2` cannot fail here in principle (the disc always
			# leaves at least the tangent point of `line` itself available);
			# keep the previous result as a safe fallback if it ever does.
			if typeof(solved) == TYPE_DICTIONARY:
				result = solved["velocity"]
			distance = (line["direction"] as Vector2).cross((line["point"] as Vector2) - result)
	return result


static func _flat(value: Vector3) -> Vector2:
	return Vector2(value.x, value.z)
