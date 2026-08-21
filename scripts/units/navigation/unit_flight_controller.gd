class_name UnitFlightController
extends RefCounted
## Owned by `Unit` only when `unit_definition.can_fly` is true (see
## `Unit._apply_unit_definition()`). Drives fixed-altitude flight, the
## takeoff/land/hover/fly animation state machine, and the vertical air-air
## avoidance offset. Holds no cached `AnimationPlayer` references — it always
## asks `Unit` for the current players via `flight_play_clip`/`flight_clip_length`,
## so a mid-life `replace_visual_scene()` swap can't leave it stale.

const RuleTicksScript := preload("res://scripts/rules/rule_ticks.gd")

enum Phase {
	GROUNDED,
	HANGAR_EXIT,
	TAKING_OFF,
	CRUISING,
	HOVERING,
	LANDING,
	LANDED,
	PICKUP_LAND,
	PICKUP_START,
	PICKUP_LIFT,
	PICKUP_END,
	PICKUP_TAKEOFF,
}

const FLY_ANIMATION := &"Fly"
const HOVER_ANIMATION := &"Hover"
const FLY_TO_HOVER_ANIMATION := &"FlyToHover"
const HOVER_TO_FLY_ANIMATION := &"HoverToFly"
const LAND_ANIMATION := &"Land"
const TAKEOFF_ANIMATION := &"Takeoff"
const PICKUP_START_ANIMATION := &"StartPickup"
const PICKUP_ANIMATION := &"Pickup"
const PICKUP_END_ANIMATION := &"EndPickup"

const DEFAULT_TAKEOFF_SECONDS := 1.5
const DEFAULT_LAND_SECONDS := 1.5
## Fallback only: every shipped flying model has both transition clips (see
## tests/units/flight_run.gd's _test_flight_clip_catalog), so
## flight_clip_length() finds the authored duration in practice.
const DEFAULT_TRANSITION_SECONDS := 1.0
## Mirrors Unit.SLOPE_ALIGNMENT_RESPONSE's role: exponential blend rate toward
## the vertical-avoidance target set by UnitLocalAvoidance.
const VERTICAL_AVOIDANCE_RESPONSE := 4.0
## Aircraft should not trace every narrow ridge in the terrain. A deliberately
## slow exponential response gives cruising aircraft strong vertical inertia:
## brief height changes barely affect them, while a hovering aircraft still
## settles toward the correct terrain-relative altitude over several seconds.
const TERRAIN_ALTITUDE_RESPONSE := 0.2
## Shared flight level above the terrain. This is kept separate from the
## per-unit Rules.txt HeightOffset so the common altitude can be tuned without
## exaggerating the small differences between aircraft types.
const BASE_FLIGHT_ALTITUDE := 24.0
## HeightOffset uses the same source-coordinate space as converted models and
## terrain: sixteen source units correspond to one Godot world unit.
const HEIGHT_OFFSET_WORLD_SCALE := 0.0625
## `Circles` craft are fixed-wing aircraft. Rules.txt TurnRate is radians per
## 20 Hz movement update, so this is also the angular speed used to derive a
## physical minimum turn radius rather than an arbitrary hover-circle radius.
## Local alias of RuleTicks.RULE_MOVEMENT_UPDATES_PER_SECOND -- see that
## constant's doc comment -- kept here, unqualified, because
## tests/units/flight_run.gd reads it as UnitFlightControllerScript.<const>.
const MOVEMENT_UPDATES_PER_SECOND := RuleTicksScript.RULE_MOVEMENT_UPDATES_PER_SECOND
const IDLE_CRUISE_SPEED_SCALE := 1.0 / 3.0
## Idle loiter uses a broad, gentle orbit. Ordered manoeuvres retain the full
## Rules.txt TurnRate. Scaling angular speed by the same 2/3 factor as the
## revised idle speed preserves the expanded radius while slowing the circuit.
const IDLE_CRUISE_TURN_RATE_SCALE := 1.0 / 6.0
const MAX_BANK_ANGLE := deg_to_rad(35.0)

var phase: Phase = Phase.GROUNDED
## Current world-space target altitude. During flight it is recomputed from
## the static terrain mesh directly below the unit plus `height_offset`;
## buildings are excluded by Unit._terrain_hit_at()'s terrain-only mask.
var cruise_altitude := 0.0
var ground_altitude := 0.0
var height_offset := 0.0
var ornithoptor := false
var carryall := false
var advanced_carryall := false
var circles := false

var _unit  # Unit — untyped to avoid a cyclic preload with unit.gd
var _phase_elapsed := 0.0
var _helipad_resource_id: StringName = &""
var _vertical_avoidance_offset := 0.0
var _vertical_avoidance_target := 0.0
var _post_takeoff_move_target := Vector3.INF
var _post_takeoff_exit_point := Vector3.INF
var _landing_target := Vector3.INF
var _landing_allowed_cells: Dictionary = {}
var _cruise_moving := false
var _cruise_state_initialized := false
## The Fly<->Hover transition completes on a tick deadline computed once when
## it starts (flight_clip_length(), the same one-time-lookup-of-authored-data
## idiom as flight_landing_approach_radius() and AuthoredFireController's
## shot_times), not on the clip's own animation_finished signal -- see
## _advance_transition()'s doc comment.
var _transition_active := false
var _transition_clip: StringName = &""
var _transition_elapsed := 0.0
var _transition_duration := 0.0
var _circles_order_active := false
var _circles_order_completed := false
var _circles_destination := Vector3.INF
## A short forward departure is the deterministic close-target manoeuvre.
## It prevents a minimum-radius aircraft from trying to orbit forever around
## an order that lies inside its initial turning circle.
var _circles_departure := Vector3.INF
## True after the one optional close-target departure has been planned. It
## must survive reaching that waypoint, otherwise a close order would keep
## creating fresh departure legs forever.
var _circles_departure_planned := false
var _circles_idle_turn_sign := 1.0
var _visual_bank := 0.0
## A transport owns the order between pickup clips.  The flight controller
## advances the authored clip/vertical motion and exposes completion, but
## never decides when a cargo is attached or detached.
var _pickup_transition_finished := false
var _pickup_landing_target := Vector3.INF
var _pickup_landing_altitude := 0.0
var _pickup_cruise_altitude := 0.0
var _pickup_landing_start_altitude := 0.0


func configure(unit, unit_definition) -> void:
	_unit = unit
	height_offset = float(unit_definition.height_offset) * HEIGHT_OFFSET_WORLD_SCALE
	cruise_altitude = _unit.global_position.y + BASE_FLIGHT_ALTITUDE + height_offset
	ornithoptor = bool(unit_definition.ornithoptor)
	carryall = bool(unit_definition.carryall)
	advanced_carryall = bool(unit_definition.advanced_carryall)
	circles = bool(unit_definition.circles)
	_circles_order_active = false
	_circles_order_completed = false
	_circles_destination = Vector3.INF
	_circles_departure = Vector3.INF
	_circles_departure_planned = false
	_visual_bank = 0.0
	_landing_target = Vector3.INF
	_pickup_landing_target = Vector3.INF
	_helipad_resource_id = &""
	for value in unit_definition.resource_ids:
		_helipad_resource_id = StringName(String(value))
		break


func flight_is_airborne_phase() -> bool:
	return phase != Phase.GROUNDED and phase != Phase.HANGAR_EXIT and phase != Phase.LANDED


func flight_is_landed() -> bool:
	return phase == Phase.GROUNDED or phase == Phase.LANDED


func flight_is_taking_off() -> bool:
	return phase == Phase.TAKING_OFF


func flight_controls_transition() -> bool:
	return phase == Phase.HANGAR_EXIT or phase == Phase.TAKING_OFF


func flight_navigation_is_locked() -> bool:
	return phase == Phase.LANDING \
		or phase == Phase.PICKUP_LAND \
		or phase == Phase.PICKUP_START \
		or phase == Phase.PICKUP_LIFT \
		or phase == Phase.PICKUP_END \
		or phase == Phase.PICKUP_TAKEOFF


## Begin the authored descent far enough from the destination that ordinary
## flight speed can cover the remaining horizontal distance during Land.
func flight_landing_approach_radius() -> float:
	var duration: float = _unit.flight_clip_length(LAND_ANIMATION, DEFAULT_LAND_SECONDS)
	return maxf(
		float(_unit.arrival_radius),
		maxf(float(_unit.navigation_move_speed()), 0.0) * maxf(duration, 0.0)
	)


## A normal move order supersedes only a not-yet-started landing approach.
## Once Land owns the transition, transport/flight command locking decides
## when another order may be accepted.
func cancel_pending_landing() -> void:
	if phase != Phase.CRUISING and phase != Phase.HOVERING:
		return
	_landing_target = Vector3.INF
	_landing_allowed_cells.clear()


func can_enter_ornithopter_land_cycle() -> bool:
	return ornithoptor


func can_enter_pickup_sequence() -> bool:
	return carryall or advanced_carryall


## Called only by UnitRosterController right after spawn (Unit.begin_hangar_takeoff).
func begin_hangar_takeoff(rally_point: Vector3, exit_point: Vector3) -> void:
	_post_takeoff_move_target = rally_point
	_post_takeoff_exit_point = Vector3.INF
	if not exit_point.is_finite():
		_start_takeoff(rally_point, Vector3.INF)
		return
	var exit_offset: Vector3 = exit_point - _unit.global_position
	exit_offset.y = 0.0
	if exit_offset.length() <= float(_unit.arrival_radius):
		_start_takeoff(rally_point, Vector3.INF)
		return
	_post_takeoff_exit_point = exit_point
	phase = Phase.HANGAR_EXIT
	_phase_elapsed = 0.0
	_unit.flight_set_movement_animation(true)


## Called from Unit.move_to() when a landed flyer receives a new order.
func begin_takeoff_toward(world_position: Vector3, exit_point: Vector3) -> void:
	_start_takeoff(world_position, exit_point)


func _start_takeoff(move_target: Vector3, exit_point: Vector3) -> void:
	_post_takeoff_move_target = move_target
	_post_takeoff_exit_point = exit_point
	phase = Phase.TAKING_OFF
	_phase_elapsed = 0.0
	ground_altitude = _sample_ground_altitude(_unit.global_position)
	cruise_altitude = ground_altitude + BASE_FLIGHT_ALTITUDE + height_offset
	_unit.flight_play_clip(TAKEOFF_ANIMATION, false, 1.0)


## Only Ornithopters (ammo-replenish docking) or carriers (pickup sequence) may
## ever leave CRUISING/HOVERING to land — every other CanFly unit only takes
## off once, at spawn, and never lands again. A distant target remains an
## ordinary flight order until it enters the authored Land approach radius.
func flight_request_land(target_position: Vector3, allowed_cells: Dictionary) -> bool:
	if phase != Phase.CRUISING and phase != Phase.HOVERING:
		return false
	if not (can_enter_ornithopter_land_cycle() or can_enter_pickup_sequence()):
		return false
	if not target_position.is_finite():
		return false
	_landing_target = target_position
	_landing_allowed_cells = allowed_cells
	if _landing_approach_reached():
		_start_landing_descent()
	else:
		_unit.flight_continue_navigation(target_position)
	return true


func _start_landing_descent() -> void:
	phase = Phase.LANDING
	_phase_elapsed = 0.0
	_unit.flight_stop_navigation_for_transition()
	clear_circles_order()
	_visual_bank = 0.0
	_unit.flight_set_visual_bank(0.0)
	ground_altitude = _sample_ground_altitude(_landing_target)
	_unit.flight_play_clip(LAND_ANIMATION, false, 1.0)


func _landing_approach_reached() -> bool:
	if not _landing_target.is_finite():
		return false
	var offset: Vector3 = _landing_target - _unit.global_position
	offset.y = 0.0
	return offset.length() <= flight_landing_approach_radius()


func flight_set_vertical_offset(value: float) -> void:
	_vertical_avoidance_target = value


func circles_flight_enabled() -> bool:
	return circles and (phase == Phase.CRUISING or phase == Phase.HOVERING)


func set_circles_order(destination: Vector3) -> void:
	if not circles:
		return
	# Preserve the exact (already map-bounded) navigation destination. The
	# horizontal integrator ignores Y, but keeping the same value makes the
	# controller and navigation agent auditable and prevents target drift.
	_circles_destination = destination
	_circles_departure = Vector3.INF
	_circles_departure_planned = false
	_circles_order_active = true
	_circles_order_completed = false
	_plan_close_target_departure()


func clear_circles_order() -> void:
	if not circles:
		return
	_circles_order_active = false
	_circles_departure = Vector3.INF
	_circles_departure_planned = false


func consume_circles_order_completed() -> bool:
	var completed := _circles_order_completed
	_circles_order_completed = false
	return completed


func circles_order_is_active() -> bool:
	return circles and _circles_order_active


## The nominal velocity supplied to AirNavigation. Its direction is the next
## constrained-curvature steering target; AirNavigation may add its existing
## lateral separation velocity before calling `advance_circles_flight`.
func circles_desired_velocity() -> Vector3:
	if not circles_flight_enabled():
		return Vector3.ZERO
	var speed := _circles_speed()
	var target := _circles_steering_target()
	var offset: Vector3 = target - _unit.global_position
	offset.y = 0.0
	if offset.length_squared() <= 0.000001:
		return _unit.facing_direction() * speed
	return offset.normalized() * speed


## Fixed-wing horizontal integrator. Unlike Unit.navigation_step's ordinary
## locomotion, it never converts a pending turn into zero translation.
func advance_circles_flight(steering_velocity: Vector3, delta: float) -> Vector3:
	if not circles_flight_enabled() or delta <= 0.0:
		return Vector3.ZERO
	_ensure_circles_cruising()
	if _circles_order_active and _reached(_circles_destination, float(_unit.arrival_radius)):
		_finish_circles_order()

	var desired_direction := Vector3(steering_velocity.x, 0.0, steering_velocity.z)
	if desired_direction.length_squared() <= 0.000001:
		var target := _circles_steering_target()
		desired_direction = target - _unit.global_position
		desired_direction.y = 0.0
	if desired_direction.length_squared() <= 0.000001:
		desired_direction = _unit.facing_direction()
	if not _circles_order_active:
		# An idle orbit is a sustained maximum-rate turn, hence it retains its
		# corresponding bank instead of becoming a Hover animation.
		# `_rotated_horizontal` uses the XZ mathematical convention while
		# Godot yaw has the opposite sign for a local -Z forward model.
		desired_direction = _rotated_horizontal(_unit.facing_direction(), -_circles_idle_turn_sign * PI * 0.5)

	var yaw_before: float = _unit.global_rotation.y
	var turn_delta := delta if _circles_order_active else delta * IDLE_CRUISE_TURN_RATE_SCALE
	_unit.turn_toward(desired_direction, turn_delta)
	var yaw_after: float = _unit.global_rotation.y
	var yaw_delta := angle_difference(yaw_before, yaw_after)
	_update_visual_bank(yaw_delta, delta)

	var speed := _circles_speed()
	var forward: Vector3 = _unit.facing_direction()
	forward.y = 0.0
	if forward.length_squared() <= 0.000001:
		return Vector3.ZERO
	forward = forward.normalized()
	var start: Vector3 = _unit.global_position
	var end: Vector3 = start + forward * speed * delta
	if _circles_order_active:
		var segment_target := _circles_steering_target()
		if _segment_reaches(start, end, segment_target, float(_unit.arrival_radius)):
			_unit.global_position = Vector3(segment_target.x, start.y, segment_target.z)
			if _circles_departure.is_finite():
				_circles_departure = Vector3.INF
			else:
				_finish_circles_order()
			return forward * speed
	_unit.global_position = end
	return forward * speed


func _circles_steering_target() -> Vector3:
	if not _circles_order_active:
		return _unit.global_position + _unit.facing_direction()
	if _circles_departure.is_finite():
		return _circles_departure
	return _circles_destination


func _plan_close_target_departure() -> void:
	if _circles_departure_planned:
		return
	_circles_departure_planned = true
	var offset: Vector3 = _circles_destination - _unit.global_position
	offset.y = 0.0
	if offset.length() >= _minimum_turn_radius() * 2.0:
		return
	# A target inside two radii cannot be joined reliably by the first turn.
	# Plan one forward departure when the order arrives, then fly the actual
	# target after this waypoint; do not create another leg when it is crossed.
	var forward: Vector3 = _unit.facing_direction()
	forward.y = 0.0
	if forward.length_squared() > 0.000001:
		_circles_departure = _unit.global_position + forward.normalized() * _minimum_turn_radius() * 2.0


func _circles_speed() -> float:
	var scale := 1.0 if _circles_order_active else IDLE_CRUISE_SPEED_SCALE
	return maxf(float(_unit.navigation_move_speed()) * scale, 0.0)


func _minimum_turn_radius() -> float:
	var angular_speed := maxf(float(_unit.turn_rate) * MOVEMENT_UPDATES_PER_SECOND, 0.0001)
	return maxf(float(_unit.navigation_move_speed()) / angular_speed, float(_unit.arrival_radius))


func _ensure_circles_cruising() -> void:
	if phase == Phase.HOVERING:
		phase = Phase.CRUISING
	_transition_active = false
	_transition_clip = &""
	_cruise_state_initialized = true
	_cruise_moving = true
	_unit.flight_play_clip(FLY_ANIMATION, true, 1.0)


func _finish_circles_order() -> void:
	_circles_order_active = false
	_circles_order_completed = true
	_circles_departure = Vector3.INF
	_circles_departure_planned = false


func _update_visual_bank(yaw_delta: float, delta: float) -> void:
	var maximum_yaw_speed := maxf(float(_unit.turn_rate) * MOVEMENT_UPDATES_PER_SECOND, 0.0001)
	var normalized_rate := clampf(yaw_delta / maxf(maximum_yaw_speed * delta, 0.0001), -1.0, 1.0)
	# Positive yaw is a left turn in Godot's Y-up coordinates. Rolling the
	# model the opposite way puts the wing down on the inside of the turn.
	_visual_bank = -normalized_rate * MAX_BANK_ANGLE
	if not is_zero_approx(yaw_delta):
		_circles_idle_turn_sign = signf(yaw_delta)
	_unit.flight_set_visual_bank(_visual_bank)


static func _rotated_horizontal(direction: Vector3, angle: float) -> Vector3:
	return Vector3(
		direction.x * cos(angle) - direction.z * sin(angle),
		0.0,
		direction.x * sin(angle) + direction.z * cos(angle)
	)


func _reached(target: Vector3, radius: float) -> bool:
	var offset: Vector3 = target - _unit.global_position
	offset.y = 0.0
	return offset.length() <= radius


static func _segment_reaches(start: Vector3, end: Vector3, target: Vector3, radius: float) -> bool:
	var segment := end - start
	segment.y = 0.0
	var to_target := target - start
	to_target.y = 0.0
	var length_squared := segment.length_squared()
	if length_squared <= 0.000001:
		return to_target.length() <= radius
	var t := clampf(to_target.dot(segment) / length_squared, 0.0, 1.0)
	return (to_target - segment * t).length() <= radius


## Pickup sequence is scheduled by AdvancedCarryallTransport.  This controller
## owns the authored clip progression and vertical body transform only.
func flight_begin_pickup_sequence(
	landing_position := Vector3.INF, landing_clearance := 0.0
) -> void:
	if not can_enter_pickup_sequence():
		return
	phase = Phase.PICKUP_LAND
	_phase_elapsed = 0.0
	_pickup_transition_finished = false
	clear_circles_order()
	_visual_bank = 0.0
	_unit.flight_set_visual_bank(0.0)
	var landing: Vector3 = landing_position if landing_position.is_finite() else _unit.global_position
	_pickup_landing_target = landing
	var terrain_altitude := _sample_ground_altitude(landing)
	_pickup_landing_altitude = terrain_altitude + maxf(landing_clearance, 0.0)
	_pickup_landing_start_altitude = _unit.global_position.y
	_pickup_cruise_altitude = maxf(
		terrain_altitude + BASE_FLIGHT_ALTITUDE + height_offset,
		_pickup_landing_altitude
	)
	_unit.flight_play_clip(LAND_ANIMATION, false, 1.0)


func flight_advance_pickup(next_sub_phase: Phase) -> void:
	phase = next_sub_phase
	_phase_elapsed = 0.0
	_pickup_transition_finished = false
	match next_sub_phase:
		Phase.PICKUP_START:
			_unit.flight_play_clip(PICKUP_START_ANIMATION, false, 1.0)
		Phase.PICKUP_LIFT:
			_unit.flight_play_clip(PICKUP_ANIMATION, false, 1.0)
		Phase.PICKUP_END:
			_unit.flight_play_clip(PICKUP_END_ANIMATION, false, 1.0)


func flight_complete_pickup_sequence() -> void:
	# Start Takeoff from the transport's present altitude.  During a normal
	# pickup/drop this is the fixed docking height held throughout StartPickup,
	# Pickup and EndPickup.  Keeping the actual position also lets an aborted
	# landing recover without first snapping down to the intended docking height.
	_post_takeoff_move_target = _unit.global_position
	_post_takeoff_exit_point = Vector3.INF
	phase = Phase.TAKING_OFF
	_phase_elapsed = 0.0
	ground_altitude = _unit.global_position.y
	cruise_altitude = _pickup_cruise_altitude
	_unit.flight_play_clip(TAKEOFF_ANIMATION, false, 1.0)


func flight_pickup_transition_finished() -> bool:
	return _pickup_transition_finished


## Pickup/drop transport remains command-locked through Takeoff.  The state
## machine uses this instead of treating `begin_takeoff` as an instantaneous
## completion, so a player cannot slip a normal order into the transition.
func flight_transport_takeoff_finished() -> bool:
	return phase == Phase.CRUISING or phase == Phase.HOVERING


## Called unconditionally every tick from Unit._snap_to_terrain(delta) whenever
## a flight controller exists.
func advance(delta: float) -> void:
	if phase == Phase.GROUNDED or phase == Phase.LANDED:
		_unit.flight_snap_to_terrain()
		return
	if phase == Phase.HANGAR_EXIT:
		_advance_hangar_exit(delta)
		return
	if phase == Phase.TAKING_OFF:
		_advance_vertical_transition(
			delta, TAKEOFF_ANIMATION, DEFAULT_TAKEOFF_SECONDS,
			ground_altitude, cruise_altitude, Phase.CRUISING,
			_takeoff_motion_target()
		)
		return
	if phase == Phase.LANDING:
		_advance_vertical_transition(
			delta, LAND_ANIMATION, DEFAULT_LAND_SECONDS,
			cruise_altitude, ground_altitude, Phase.LANDED,
			_landing_target
		)
		return
	if phase == Phase.CRUISING or phase == Phase.HOVERING:
		if _landing_approach_reached():
			_start_landing_descent()
			return
		_advance_transition(delta)
		_advance_vertical_avoidance(delta)
		_advance_cruise_altitude(delta)
		_unit.global_position.y = cruise_altitude + _vertical_avoidance_offset
		_unit.flight_set_visual_slope_target(Vector3.UP)
		return
	if phase == Phase.PICKUP_LAND:
		_advance_pickup_landing(delta)
		return
	if phase == Phase.PICKUP_START:
		_advance_pickup_clip(delta, PICKUP_START_ANIMATION, DEFAULT_LAND_SECONDS)
		return
	if phase == Phase.PICKUP_LIFT:
		_advance_pickup_clip(delta, PICKUP_ANIMATION, DEFAULT_LAND_SECONDS)
		return
	if phase == Phase.PICKUP_END:
		_advance_pickup_clip(delta, PICKUP_END_ANIMATION, DEFAULT_LAND_SECONDS)
		return


func _advance_hangar_exit(delta: float) -> void:
	var exit_offset: Vector3 = _post_takeoff_exit_point - _unit.global_position
	exit_offset.y = 0.0
	var distance: float = exit_offset.length()
	var arrival := float(_unit.arrival_radius)
	if distance > arrival and delta > 0.0:
		var step: float = minf(float(_unit.navigation_move_speed()) * delta, distance)
		_unit.global_position += exit_offset / distance * step
		_unit.flight_snap_to_terrain()
		_unit.flight_set_movement_animation(true)
		return
	_start_takeoff(_post_takeoff_move_target, Vector3.INF)


func _advance_vertical_transition(
		delta: float,
		clip_name: StringName,
		default_seconds: float,
		from_altitude: float,
		to_altitude: float,
		next_phase: Phase,
		horizontal_target := Vector3.INF
	) -> void:
	_phase_elapsed += delta
	if horizontal_target.is_finite():
		_unit.flight_advance_transition_motion(horizontal_target, delta)
	var duration: float = _unit.flight_clip_length(clip_name, default_seconds)
	var t := clampf(_phase_elapsed / duration, 0.0, 1.0) if duration > 0.0 else 1.0
	_unit.global_position.y = lerpf(from_altitude, to_altitude, t)
	_unit.flight_set_visual_slope_target(Vector3.UP)
	if t < 1.0:
		return
	phase = next_phase
	_phase_elapsed = 0.0
	if next_phase == Phase.CRUISING:
		_cruise_state_initialized = false
		_unit.flight_continue_navigation(_post_takeoff_move_target, _post_takeoff_exit_point)
	elif next_phase == Phase.LANDED:
		_landing_target = Vector3.INF
		_landing_allowed_cells.clear()


func _takeoff_motion_target() -> Vector3:
	return _post_takeoff_exit_point \
		if _post_takeoff_exit_point.is_finite() else _post_takeoff_move_target


func flight_update_pickup_landing_target(world_position: Vector3) -> void:
	if phase == Phase.PICKUP_LAND and world_position.is_finite():
		_pickup_landing_target = world_position


func _advance_pickup_landing(delta: float) -> void:
	if _pickup_landing_target.is_finite():
		# AdvancedCarryallTransport aligns the hull with the cargo's authored
		# pickup axis. Do not replace that constrained facing with travel heading.
		_unit.flight_advance_transition_motion(_pickup_landing_target, delta, false)
	if _pickup_transition_finished:
		return
	_phase_elapsed += maxf(delta, 0.0)
	var duration: float = _unit.flight_clip_length(LAND_ANIMATION, DEFAULT_LAND_SECONDS)
	var t := clampf(_phase_elapsed / duration, 0.0, 1.0) if duration > 0.0 else 1.0
	_unit.global_position.y = lerpf(_pickup_landing_start_altitude, _pickup_landing_altitude, t)
	_unit.flight_set_visual_slope_target(Vector3.UP)
	if t >= 1.0:
		_pickup_transition_finished = true


func _advance_pickup_clip(delta: float, clip_name: StringName, fallback_seconds: float) -> void:
	if _pickup_transition_finished:
		return
	_phase_elapsed += maxf(delta, 0.0)
	var duration: float = _unit.flight_clip_length(clip_name, fallback_seconds)
	if duration <= 0.0 or _phase_elapsed >= duration:
		_pickup_transition_finished = true


func _advance_vertical_avoidance(delta: float) -> void:
	if delta <= 0.0:
		return
	var blend := clampf(1.0 - exp(-VERTICAL_AVOIDANCE_RESPONSE * delta), 0.0, 1.0)
	_vertical_avoidance_offset = lerpf(_vertical_avoidance_offset, _vertical_avoidance_target, blend)


func _advance_cruise_altitude(delta: float) -> void:
	if delta <= 0.0:
		return
	var target_altitude := _sample_flight_altitude(_unit.global_position)
	var blend := clampf(1.0 - exp(-TERRAIN_ALTITUDE_RESPONSE * delta), 0.0, 1.0)
	cruise_altitude = lerpf(cruise_altitude, target_altitude, blend)


## Fly<->Hover sub-FSM, only relevant while phase is CRUISING/HOVERING — the
## outer takeoff/land phase is driven separately by advance(). Called every
## tick from Unit._set_movement_animation() while airborne.
func set_cruise_moving(is_moving: bool, speed_scale: float) -> void:
	if phase != Phase.CRUISING and phase != Phase.HOVERING:
		return
	if circles:
		# Fixed-wing `Circles` units never enter Hover just because their last
		# order completed. The horizontal controller keeps them in Fly at one
		# third of their physical speed while idle.
		_ensure_circles_cruising()
		return
	if not _cruise_state_initialized:
		_cruise_state_initialized = true
		_cruise_moving = is_moving
		phase = Phase.CRUISING if is_moving else Phase.HOVERING
		_play_cruise_state_clip(is_moving, speed_scale)
		return
	if is_moving == _cruise_moving:
		if is_moving and not _transition_active:
			_unit.flight_play_clip(FLY_ANIMATION, true, speed_scale)
		return
	_cruise_moving = is_moving
	if is_moving:
		phase = Phase.CRUISING
		_transition_clip = HOVER_TO_FLY_ANIMATION
	else:
		phase = Phase.HOVERING
		_transition_clip = FLY_TO_HOVER_ANIMATION
	var player: AnimationPlayer = _unit.flight_play_clip(_transition_clip, false, 1.0)
	if player == null:
		_transition_clip = &""
		_play_cruise_state_clip(is_moving, speed_scale)
		return
	# Duration read once from the clip, exactly like flight_landing_approach_
	# radius() and the other flight_clip_length() call sites -- a one-time
	# lookup of authored data, not a live read of the player's position or a
	# wait on its finished signal. The clip itself keeps playing on `player`
	# for the look; _advance_transition() owns when the transition actually
	# completes.
	_transition_duration = _unit.flight_clip_length(_transition_clip, DEFAULT_TRANSITION_SECONDS)
	_transition_elapsed = 0.0
	_transition_active = true


func _play_cruise_state_clip(is_moving: bool, speed_scale: float) -> void:
	if is_moving:
		_unit.flight_play_clip(FLY_ANIMATION, true, speed_scale)
	else:
		_unit.flight_play_clip(HOVER_ANIMATION, true, 1.0)


## Completes the Fly<->Hover transition once `_transition_duration` (read
## once, at transition start, from the clip's authored length) has elapsed on
## the simulation tick -- never on the clip's own animation_finished signal,
## which fires on engine frame time and made how many ticks a transition took
## depend on how fast the machine ran (see the "Updated after slice B2"
## paragraph in docs/architecture/network-multiplayer.md). Called every tick
## from advance() while CRUISING/HOVERING; the clip keeps playing on its
## player for the look regardless of when this fires.
func _advance_transition(delta: float) -> void:
	if not _transition_active:
		return
	_transition_elapsed += maxf(delta, 0.0)
	if _transition_elapsed < _transition_duration:
		return
	_transition_active = false
	_transition_clip = &""
	_play_cruise_state_clip(_cruise_moving, 1.0)


func _sample_ground_altitude(position: Vector3) -> float:
	var hit: Dictionary = _unit.flight_terrain_hit_at(position)
	if hit.is_empty():
		return position.y
	return (hit["position"] as Vector3).y


func _sample_flight_altitude(position: Vector3) -> float:
	var hit: Dictionary = _unit.flight_terrain_hit_at(position)
	if hit.is_empty():
		# Synthetic scenes and off-map flight may have no terrain collider.
		# Preserve the current base altitude instead of adding the offset again
		# on every frame.
		return position.y - _vertical_avoidance_offset
	return (hit["position"] as Vector3).y + BASE_FLIGHT_ALTITUDE + height_offset
