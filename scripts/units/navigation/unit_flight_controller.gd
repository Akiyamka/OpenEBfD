class_name UnitFlightController
extends RefCounted
## Owned by `Unit` only when `unit_definition.can_fly` is true (see
## `Unit._apply_unit_definition()`). Drives fixed-altitude flight, the
## takeoff/land/hover/fly animation state machine, and the vertical air-air
## avoidance offset. Holds no cached `AnimationPlayer` references — it always
## asks `Unit` for the current players via `flight_play_clip`/`flight_clip_length`,
## so a mid-life `replace_visual_scene()` swap can't leave it stale.

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
var _transition_player: AnimationPlayer = null
var _transition_clip: StringName = &""


func configure(unit, unit_definition) -> void:
	_unit = unit
	height_offset = float(unit_definition.height_offset) * HEIGHT_OFFSET_WORLD_SCALE
	cruise_altitude = _unit.global_position.y + BASE_FLIGHT_ALTITUDE + height_offset
	ornithoptor = bool(unit_definition.ornithoptor)
	carryall = bool(unit_definition.carryall)
	advanced_carryall = bool(unit_definition.advanced_carryall)
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
## off once, at spawn, and never lands again. `allowed_cells` is accepted now
## (matching the command_dock exception shape) for the follow-up pass that
## wires an actual land order; this pass does not issue any nav order itself.
func flight_request_land(target_position: Vector3, allowed_cells: Dictionary) -> bool:
	if phase != Phase.CRUISING and phase != Phase.HOVERING:
		return false
	if not (can_enter_ornithopter_land_cycle() or can_enter_pickup_sequence()):
		return false
	phase = Phase.LANDING
	_phase_elapsed = 0.0
	_landing_target = target_position
	_landing_allowed_cells = allowed_cells
	ground_altitude = _sample_ground_altitude(target_position)
	_unit.flight_play_clip(LAND_ANIMATION, false, 1.0)
	return true


func flight_set_vertical_offset(value: float) -> void:
	_vertical_avoidance_target = value


## Pickup sequence — stub only, per scope. Phase/clip constants exist and are
## individually triggerable; nothing drives the sub-phases automatically yet
## (that is the follow-up carryall-AI pass).
func flight_begin_pickup_sequence() -> void:
	if not can_enter_pickup_sequence():
		return
	phase = Phase.PICKUP_LAND
	_phase_elapsed = 0.0
	_unit.flight_play_clip(LAND_ANIMATION, false, 1.0)


func flight_advance_pickup(next_sub_phase: Phase) -> void:
	phase = next_sub_phase
	_phase_elapsed = 0.0
	match next_sub_phase:
		Phase.PICKUP_START:
			_unit.flight_play_clip(PICKUP_START_ANIMATION, false, 1.0)
		Phase.PICKUP_LIFT:
			_unit.flight_play_clip(PICKUP_ANIMATION, false, 1.0)
		Phase.PICKUP_END:
			_unit.flight_play_clip(PICKUP_END_ANIMATION, false, 1.0)


func flight_complete_pickup_sequence() -> void:
	# The follow-up carryall-AI pass supplies the real post-lift destination.
	_start_takeoff(_unit.global_position, Vector3.INF)


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
			ground_altitude, cruise_altitude, Phase.CRUISING
		)
		return
	if phase == Phase.LANDING:
		_advance_vertical_transition(
			delta, LAND_ANIMATION, DEFAULT_LAND_SECONDS,
			cruise_altitude, ground_altitude, Phase.LANDED
		)
		return
	if phase == Phase.CRUISING or phase == Phase.HOVERING:
		_advance_vertical_avoidance(delta)
		_advance_cruise_altitude(delta)
		_unit.global_position.y = cruise_altitude + _vertical_avoidance_offset
		_unit.flight_set_visual_slope_target(Vector3.UP)
		return
	# Pickup sub-phases: stub only, no automatic advancement this pass.


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
		next_phase: Phase
	) -> void:
	_phase_elapsed += delta
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
		_unit.move_to(_post_takeoff_move_target, _post_takeoff_exit_point)


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
	if not _cruise_state_initialized:
		_cruise_state_initialized = true
		_cruise_moving = is_moving
		phase = Phase.CRUISING if is_moving else Phase.HOVERING
		_play_cruise_state_clip(is_moving, speed_scale)
		return
	if is_moving == _cruise_moving:
		if is_moving and _transition_player == null:
			_unit.flight_play_clip(FLY_ANIMATION, true, speed_scale)
		return
	_cruise_moving = is_moving
	if is_moving:
		phase = Phase.CRUISING
		_transition_clip = HOVER_TO_FLY_ANIMATION
	else:
		phase = Phase.HOVERING
		_transition_clip = FLY_TO_HOVER_ANIMATION
	_transition_player = _unit.flight_play_clip(_transition_clip, false, 1.0)
	if _transition_player == null:
		_transition_clip = &""
		_play_cruise_state_clip(is_moving, speed_scale)


func _play_cruise_state_clip(is_moving: bool, speed_scale: float) -> void:
	if is_moving:
		_unit.flight_play_clip(FLY_ANIMATION, true, speed_scale)
	else:
		_unit.flight_play_clip(HOVER_ANIMATION, true, 1.0)


## Called from Unit._on_animation_finished() for every player; returns true
## only when this was the Fly<->Hover transition clip this controller started,
## in which case it has fully handled the event (mirrors the deployment/fire
## sequence early-return branches already in that function).
func notify_animation_finished(animation_name: StringName, player: AnimationPlayer) -> bool:
	if _transition_player == null or player != _transition_player or animation_name != _transition_clip:
		return false
	_transition_player = null
	_transition_clip = &""
	_play_cruise_state_clip(_cruise_moving, 1.0)
	return true


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
