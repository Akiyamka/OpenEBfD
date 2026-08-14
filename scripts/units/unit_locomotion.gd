class_name UnitLocomotion
extends RefCounted

## Movement playback and the mech gait, together — they are one state machine,
## not two. `_state` is read by the physics step (a mech contributes no
## translation while Move_Start plays), by the animation driver (which clip to
## play next) and by animation_finished (which transition just ended), so
## cutting it along a "physics vs animation" line would cut the state in half.
##
## For an ordinary vehicle this reduces to "play Move while moving, hand back
## to the idle machine while standing". For a Mech unit it additionally runs
## the authored Move_Start/Move/Move_Stop/Turn_* chain and derives the unit's
## real speed from the XBF speed events baked into the Move clip: the authored
## profile is calibrated against the MechSpeed rule through `gait_cadence()`.
##
## Caches the model's AnimationPlayers, so it implements the attach/detach
## protocol. Both entry points are idempotent — a dying unit hands off its
## model and then still gets _exit_tree().

const AuthoredFireControllerScript := preload(
	"res://scripts/combat/authored_fire_controller.gd"
)
const SpatialOrientationScript := preload("res://scripts/world/spatial_orientation.gd")

const MOVING_ANIMATION := &"Move"
const MOVE_START_ANIMATION := &"Move_Start"
const MOVE_STOP_ANIMATION := &"Move_Stop"
const TURN_LEFT_ANIMATION := &"Turn_Left"
const TURN_RIGHT_ANIMATION := &"Turn_Right"
const DEFAULT_MOVE_CYCLE_SECONDS := 1.0
## Converted XBF tracks use a 20 Hz timeline.
const BAKED_MODEL_FRAMES_PER_SECOND := 20.0

enum State {
	IDLE,
	STARTING,
	MOVING,
	TURNING_LEFT,
	TURNING_RIGHT,
	STOPPING,
}

var _unit: CharacterBody3D
var _players: Array[AnimationPlayer] = []
var _uses_mech_gait := false
var _movement_animation_active := false
var _state := State.IDLE
var _gait_elapsed := 0.0
var _start_remaining := 0.0
## Authored speed keys from the Move clip's XBF events: [{time, speed}, ...],
## sorted by time and starting at 0. Empty means "no authored profile", which
## is the ordinary non-mech case as well as a mech whose model carries none.
var _motion_profile: Array[Dictionary] = []
var _authored_average_speed := 0.0
var _motion_cycle_seconds := DEFAULT_MOVE_CYCLE_SECONDS


func configure(unit: CharacterBody3D) -> void:
	_unit = unit


func attach_model(players: Array[AnimationPlayer]) -> void:
	_players = players.duplicate()


func detach_model() -> void:
	_players.clear()


func dispose() -> void:
	detach_model()
	_unit = null


func adopt_definition(unit_definition: Resource) -> void:
	_uses_mech_gait = unit_definition != null \
		and unit_definition.mech and float(_unit.mech_speed) > 0.0
	_gait_elapsed = 0.0
	_state = State.IDLE
	_start_remaining = 0.0


func uses_mech_gait() -> bool:
	return _uses_mech_gait


func is_starting() -> bool:
	return _state == State.STARTING


func is_movement_animation_active() -> bool:
	return _movement_animation_active


## Transport interrupts the ordinary gait chain instead of letting Move_Stop
## finish. A carried unit receives no physics ticks, so leaving STARTING,
## MOVING, TURNING or STOPPING alive here would freeze that exact pose until
## after release. Return every player and the logical state to idle immediately.
func reset_to_idle(play_idle: Callable) -> void:
	_movement_animation_active = false
	_state = State.IDLE
	_gait_elapsed = 0.0
	_start_remaining = 0.0
	for player in _players:
		player.speed_scale = 1.0
		play_idle.call(player)


func gait_phase() -> float:
	return _gait_elapsed


## Places the gait at an absolute phase within the Move cycle. Used by
## tests/match/demo_boot_run.gd to sample the authored speed profile phase by
## phase without having to drive a whole walk cycle first.
func seek_gait_phase(seconds: float) -> void:
	_gait_elapsed = seconds


func authored_average_speed() -> float:
	return _authored_average_speed


## The MechSpeed rule divided by the speed the authored Move clip would give
## on its own — the factor that makes an authored walk cover the distance the
## rules ask for, applied to both playback speed and physical translation.
func gait_cadence() -> float:
	if _motion_profile.is_empty() or _authored_average_speed <= 0.0:
		return 1.0
	return float(_unit.mech_speed) / _authored_average_speed


## The navigation solver must see the phase speed before avoidance is resolved;
## applying it afterwards would let following units plan through a mech that is
## currently in its slower between-step phase.
func navigation_move_speed() -> float:
	if not _uses_mech_gait:
		return float(_unit.move_speed)
	if _motion_profile.is_empty():
		return float(_unit.mech_speed)
	return authored_phase_speed() * gait_cadence()


func authored_phase_speed() -> float:
	if _motion_profile.is_empty():
		return float(_unit.mech_speed)
	var phase := fposmod(_gait_elapsed, _motion_cycle_seconds)
	var result := float(_motion_profile[0]["speed"])
	for key in _motion_profile:
		if float(key["time"]) > phase + 0.000001:
			break
		result = float(key["speed"])
	return maxf(result, 0.0)


func movement_animation_speed_scale() -> float:
	var phase_speed := navigation_move_speed()
	var speed := (_unit.velocity as Vector3).length()
	if _uses_mech_gait and not _motion_profile.is_empty():
		var cadence := gait_cadence()
		if authored_phase_speed() <= 0.0:
			return cadence
		return cadence * speed / maxf(phase_speed, 0.000001)
	if phase_speed <= 0.0:
		return 1.0
	return speed / phase_speed


## True while a mech is in a transition clip or an authored zero-speed phase
## although its order is not finished — the frames where it must keep playing
## a movement animation despite standing still.
func transition_or_pause_has_move_order() -> bool:
	if not _uses_mech_gait or not _unit.has_active_move_order():
		return false
	if _state in [
		State.STARTING, State.TURNING_LEFT, State.TURNING_RIGHT, State.STOPPING
	]:
		return true
	return not _motion_profile.is_empty() and authored_phase_speed() <= 0.0


## A mech that has stopped translating but still owes its order some distance
## keeps a heading to steer along; ordinary units take their heading from the
## velocity they were given.
func wants_destination_heading() -> bool:
	return _uses_mech_gait and _state != State.STARTING and _unit.has_active_move_order()


func turn_animation_for(direction: Vector3) -> StringName:
	if not _uses_mech_gait or direction.length_squared() <= 0.000001:
		return &""
	var current_yaw: float = _unit.global_rotation.y
	var target_yaw := SpatialOrientationScript.yaw_facing(direction, current_yaw)
	var signed_angle := angle_difference(current_yaw, target_yaw)
	if is_zero_approx(signed_angle):
		return &""
	return TURN_LEFT_ANIMATION if signed_angle > 0.0 else TURN_RIGHT_ANIMATION


func advance_gait(delta: float, animation_speed_scale: float) -> void:
	if not _uses_mech_gait or _state != State.MOVING or delta <= 0.0:
		return
	_gait_elapsed = fposmod(
		_gait_elapsed + delta * maxf(animation_speed_scale, 0.0), _move_cycle_duration()
	)


func advance_start_transition(delta: float) -> void:
	if _state != State.STARTING or delta <= 0.0:
		return
	# Physics owns the transition deadline as well as AnimationPlayer. This
	# keeps deterministic/manual simulations moving even when no render frame
	# advances the player, while the normal animation_finished path can still
	# switch to Move first during ordinary scene playback.
	_start_remaining = maxf(_start_remaining - delta, 0.0)
	if _start_remaining <= 0.0:
		_begin_mech_move(gait_cadence())


## The movement half of Unit._set_movement_animation(): the flight and
## fire-sequence decisions stay on the facade, this owns what the model plays
## once they have passed. `play_idle` is the facade's idle machine, called for
## every player that has nothing to move to.
func apply_movement_animation(
	is_moving: bool, speed_scale: float, turn_animation: StringName, play_idle: Callable
) -> void:
	if _uses_mech_gait:
		_apply_mech_animation(is_moving, speed_scale, turn_animation, play_idle)
		return
	if not is_moving:
		_gait_elapsed = 0.0
		_start_remaining = 0.0
	_movement_animation_active = is_moving
	for player in _players:
		if is_moving and player.has_animation(MOVING_ANIMATION):
			if player.current_animation != MOVING_ANIMATION:
				player.play(MOVING_ANIMATION)
			player.speed_scale = speed_scale
			continue
		player.speed_scale = 1.0
		play_idle.call(player)


## Continues the mech chain when one of its clips ends. Returns true when the
## finished clip belonged to locomotion — including the plain "this unit is
## moving, so it must not fall into the idle chain" case.
func on_animation_finished(
	animation_name: StringName, player: AnimationPlayer, play_idle: Callable
) -> bool:
	if _uses_mech_gait:
		if _state == State.STARTING and animation_name == MOVE_START_ANIMATION:
			_begin_mech_move(gait_cadence())
			return true
		if _state == State.STOPPING and animation_name == MOVE_STOP_ANIMATION:
			_state = State.IDLE
			_start_remaining = 0.0
			for animation_player in _players:
				animation_player.speed_scale = 1.0
				play_idle.call(animation_player)
			return true
		var active_turn_animation := TURN_LEFT_ANIMATION \
			if _state == State.TURNING_LEFT else TURN_RIGHT_ANIMATION
		if (
			_state in [State.TURNING_LEFT, State.TURNING_RIGHT]
			and animation_name == active_turn_animation
			and _movement_animation_active
		):
			player.stop()
			player.play(animation_name)
			player.speed_scale = 1.0
			return true
	return _movement_animation_active


## Reads the authored Move speed events (XBF event type 11) off the model and
## turns them into the phase profile plus the average speed the cadence
## calibrates against. A model without them leaves an empty profile, and the
## unit falls back to the flat MechSpeed rule.
func refresh_motion_profile() -> void:
	_motion_profile.clear()
	_authored_average_speed = 0.0
	_motion_cycle_seconds = DEFAULT_MOVE_CYCLE_SECONDS
	var visual_root: Node3D = _unit.visual_root if _unit != null else null
	if not _uses_mech_gait or visual_root == null:
		return
	var model_root := AuthoredFireControllerScript.find_xbf_motion_root(visual_root)
	if model_root == null:
		return
	var move_entry := {}
	for entry_value: Variant in model_root.get_meta("xbf_animation_entries", []):
		var entry := entry_value as Dictionary
		if String(entry.get("name", "")).strip_edges() == String(MOVING_ANIMATION):
			move_entry = entry
			break
	if move_entry.is_empty():
		return
	var start_frame := int(move_entry.get("start_frame", -1))
	var end_frame := int(move_entry.get("end_frame", -1))
	if start_frame < 0 or end_frame < start_frame:
		return
	_motion_cycle_seconds = (
		float(end_frame - start_frame + 1) / BAKED_MODEL_FRAMES_PER_SECOND
	)
	for event_value: Variant in model_root.get_meta("xbf_fx_events", []):
		var event := event_value as Dictionary
		var frame := int(event.get("frame", -1))
		if int(event.get("type", -1)) != 11 or frame < start_frame or frame > end_frame:
			continue
		var speed := _xbf_scalar_event_value(event)
		if speed < 0.0:
			continue
		_motion_profile.append({
			"time": float(frame - start_frame) / BAKED_MODEL_FRAMES_PER_SECOND,
			"speed": speed,
		})
	_motion_profile.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return float(a["time"]) < float(b["time"])
	)
	if _motion_profile.is_empty() \
	or not is_zero_approx(float(_motion_profile[0]["time"])):
		_motion_profile.clear()
		return
	var distance_per_cycle := 0.0
	for index in _motion_profile.size():
		var segment_start := float(_motion_profile[index]["time"])
		var segment_end := _motion_cycle_seconds
		if index + 1 < _motion_profile.size():
			segment_end = float(_motion_profile[index + 1]["time"])
		distance_per_cycle += float(_motion_profile[index]["speed"]) \
			* maxf(segment_end - segment_start, 0.0)
	_authored_average_speed = distance_per_cycle / _motion_cycle_seconds
	if _authored_average_speed <= 0.0:
		_motion_profile.clear()


func _apply_mech_animation(
	is_moving: bool, move_speed_scale: float, turn_animation: StringName, play_idle: Callable
) -> void:
	var was_moving := _movement_animation_active
	_movement_animation_active = is_moving
	if not is_moving:
		_gait_elapsed = 0.0
		_start_remaining = 0.0
		if _state == State.STOPPING and _any_animation_playing(MOVE_STOP_ANIMATION):
			return
		if was_moving and _any_player_has_animation(MOVE_STOP_ANIMATION):
			_state = State.STOPPING
			_play_mech_clip(MOVE_STOP_ANIMATION, gait_cadence())
			return
		_state = State.IDLE
		for player in _players:
			player.speed_scale = 1.0
			play_idle.call(player)
		return

	if turn_animation in [TURN_LEFT_ANIMATION, TURN_RIGHT_ANIMATION] \
	and _any_player_has_animation(turn_animation):
		_start_remaining = 0.0
		_state = State.TURNING_LEFT if turn_animation == TURN_LEFT_ANIMATION \
			else State.TURNING_RIGHT
		# TurnRate already controls the physical hull yaw. These authored clips
		# describe the feet/body pose during that turn and retain their own time.
		_play_mech_clip(turn_animation, 1.0)
		return

	if _state == State.STARTING and _any_animation_playing(MOVE_START_ANIMATION):
		return
	if _state == State.MOVING:
		_play_mech_clip(MOVING_ANIMATION, move_speed_scale)
		return

	if _any_player_has_animation(MOVE_START_ANIMATION):
		_state = State.STARTING
		var start_speed_scale := gait_cadence()
		_start_remaining = _animation_playback_duration(
			MOVE_START_ANIMATION, start_speed_scale
		)
		_play_mech_clip(MOVE_START_ANIMATION, start_speed_scale)
		if _start_remaining <= 0.0:
			_begin_mech_move(move_speed_scale)
		return
	_begin_mech_move(move_speed_scale)


func _begin_mech_move(speed_scale: float) -> void:
	_state = State.MOVING
	_start_remaining = 0.0
	_play_mech_clip(MOVING_ANIMATION, speed_scale)


func _play_mech_clip(animation_name: StringName, speed_scale: float) -> void:
	for player in _players:
		var selected_animation := animation_name
		if not player.has_animation(selected_animation):
			if animation_name in [
				MOVE_START_ANIMATION,
				MOVE_STOP_ANIMATION,
				TURN_LEFT_ANIMATION,
				TURN_RIGHT_ANIMATION,
			] and player.has_animation(MOVING_ANIMATION):
				selected_animation = MOVING_ANIMATION
			else:
				continue
		if player.current_animation != selected_animation or not player.is_playing():
			if player.current_animation == selected_animation:
				player.stop()
			player.play(selected_animation)
		player.speed_scale = maxf(speed_scale, 0.0)


func _move_cycle_duration() -> float:
	if not _motion_profile.is_empty():
		return _motion_cycle_seconds
	for player in _players:
		if not player.has_animation(MOVING_ANIMATION):
			continue
		var animation := player.get_animation(MOVING_ANIMATION)
		if animation != null and animation.length > 0.0:
			return animation.length
	return DEFAULT_MOVE_CYCLE_SECONDS


func _any_player_has_animation(animation_name: StringName) -> bool:
	for player in _players:
		if player.has_animation(animation_name):
			return true
	return false


func _any_animation_playing(animation_name: StringName) -> bool:
	for player in _players:
		if (
			player.has_animation(animation_name)
			and player.current_animation == animation_name
			and player.is_playing()
		):
			return true
	return false


func _animation_playback_duration(animation_name: StringName, speed_scale: float) -> float:
	var duration := 0.0
	var safe_speed_scale := maxf(speed_scale, 0.000001)
	for player in _players:
		if not player.has_animation(animation_name):
			continue
		var animation := player.get_animation(animation_name)
		if animation != null:
			duration = maxf(duration, animation.length / safe_speed_scale)
	return duration


static func _xbf_scalar_event_value(event: Dictionary) -> float:
	if event.has("value"):
		return float(event["value"])
	var payload: Variant = event.get("raw_payload")
	if not payload is PackedByteArray or (payload as PackedByteArray).size() != 8:
		return -1.0
	var buffer := StreamPeerBuffer.new()
	buffer.data_array = payload as PackedByteArray
	return buffer.get_double()
