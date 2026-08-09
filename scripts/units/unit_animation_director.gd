class_name UnitAnimationDirector
extends RefCounted

## Owns the set of AnimationPlayers found in a unit's converted model, and the
## operations that only need the players themselves: locating a clip, starting
## one from its authored first frame, and keeping the players ahead of unit
## logic in the frame.
##
## Knows nothing about the unit -- which module currently owns the model, and
## what has to happen after a clip restarts (turret pose restoration), stay on
## the Unit facade, which passes the latter in as `after_start`.
##
## The players live in the model subtree, so this module has the same
## attach/detach lifecycle the other model-holding modules do: clear() is part
## of Unit.prepare_model_for_corpse()'s handoff, and the death-animation
## reflection test follows this object's fields to prove nothing here still
## points into a corpse.

const AuthoredModelScript := preload("res://scripts/world/authored_model.gd")

## Treats a track's very first key as the animation's starting pose. Mirrored on
## UnitCombat, which applies the same tolerance in the fire-sequence lifecycle.
const FIRE_EVENT_EPSILON := 0.0001

var _players: Array[AnimationPlayer] = []


## Re-reads the players from the model. Called on every model swap, since the
## previous set belonged to a subtree that no longer exists.
func refresh(visual_root: Node) -> Array[AnimationPlayer]:
	_players = AuthoredModelScript.animation_players(visual_root)
	return _players


func players() -> Array[AnimationPlayer]:
	return _players


func clear() -> void:
	_players.clear()


## AnimationPlayer uses internal frame processing. Converted Stationary/Move
## tracks may key the same authored pivots that combat rotates; if they run
## after Unit._process(), they erase the turret transform while its logical
## yaw/pitch continue advancing. Apply authored animation first so combat aim
## is the final transform for the frame and remains the feedback state used by
## the next frame's muzzle-to-target servo.
func prioritize_before(process_priority: int) -> void:
	for player in _players:
		player.process_priority = mini(player.process_priority, process_priority - 1)


## Shared "first player owning one of these candidate clips" scan, in
## candidate-preference order. Used by both deployment transitions and death
## animation selection so the two don't drift apart.
func find_clip(candidates: Array[StringName]) -> Dictionary:
	return AuthoredModelScript.find_clip(_players, candidates)


## Ensures `clip_name` is the active animation on the first player that has it,
## restarting playback only if it isn't already current (mirrors
## UnitLocomotion's MOVING_ANIMATION idiom, unlike play_from_start() which
## always restarts) -- safe to call every tick. Returns the player it played
## on, or null if no player has the clip.
func play_clip(clip_name: StringName, loop: bool, speed_scale: float = 1.0) -> AnimationPlayer:
	for player in _players:
		if not player.has_animation(clip_name):
			continue
		var animation := player.get_animation(clip_name)
		if animation != null:
			animation.loop_mode = Animation.LOOP_LINEAR if loop else Animation.LOOP_NONE
		if player.current_animation != clip_name:
			player.stop()
			player.play(clip_name)
		player.speed_scale = speed_scale
		return player
	return null


## Same lookup idiom as UnitLocomotion._move_cycle_duration(): the authored clip
## length if any player has it, else `fallback`.
func clip_length(clip_name: StringName, fallback: float) -> float:
	for player in _players:
		if not player.has_animation(clip_name):
			continue
		var animation := player.get_animation(clip_name)
		if animation != null and animation.length > 0.0:
			return animation.length
	return fallback


## Plays a one-shot action clip on every player that has it and returns its
## duration, so a caller can time a state on the authored length. A clip no
## model provides has zero duration, which keeps the state machine running at
## full speed instead of stalling.
func play_action(animation_name: StringName, after_start := Callable()) -> float:
	var duration := 0.0
	for player in _players:
		if not player.has_animation(animation_name):
			continue
		var animation := player.get_animation(animation_name)
		if animation != null:
			animation.loop_mode = Animation.LOOP_NONE
			duration = maxf(duration, animation.length)
		player.speed_scale = 1.0
		play_from_start(player, animation_name, after_start)
	return duration


func play_from_start(
	player: AnimationPlayer, animation_name: StringName, after_start := Callable()
) -> void:
	# Keep the outgoing pose while stopping so its first-frame effects are not
	# exposed, then apply the incoming transform pose immediately. Waiting for
	# the next AnimationPlayer tick leaves a one-frame hybrid of the outgoing
	# pose and incoming playback state (notably Kobra's vertical barrel at both
	# boundaries of its horizontal travel-mode Fire clips).
	player.stop(true)
	player.play(animation_name)
	_apply_start_transforms(player, animation_name)
	if not after_start.is_null():
		after_start.call()


func _apply_start_transforms(player: AnimationPlayer, animation_name: StringName) -> void:
	var animation := player.get_animation(animation_name)
	if animation == null:
		return
	for track in animation.get_track_count():
		if animation.track_get_type(track) != Animation.TYPE_VALUE \
		or not String(animation.track_get_path(track)).ends_with(":transform") \
		or animation.track_get_key_count(track) == 0 \
		or animation.track_get_key_time(track, 0) > FIRE_EVENT_EPSILON:
			continue
		var target := AuthoredModelScript.track_node(
			player, String(animation.track_get_path(track))
		) as Node3D
		var value: Variant = animation.track_get_key_value(track, 0)
		if target != null and value is Transform3D:
			target.transform = value as Transform3D
