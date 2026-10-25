class_name UnitFireOverlay
extends RefCounted

## Lets a unit keep firing while it drives. The authored Fire clip usually
## keys the whole body, so playing it during movement would fight the Move
## clip; this synthesizes a stripped copy that keys only the turret's own aim
## branch and layers it on a separate AnimationPlayer.
##
## A weapon qualifies only if its turret has independent yaw and its Fire clip
## touches nothing outside that turret (aircraft are exempt: their body pose
## belongs to the flight controller either way).
##
## Owns the AnimationPlayer nodes it creates, so it implements the
## attach/detach protocol — detach_model() frees them and is idempotent,
## because a dying unit hands off its model and then still gets _exit_tree().

const AuthoredModelScript := preload("res://scripts/world/authored_model.gd")

var _unit: CharacterBody3D
var _can_fire_while_moving: Dictionary = {}
var _overlays: Dictionary = {}


func configure(unit: CharacterBody3D) -> void:
	_unit = unit


## Frees the overlay nodes immediately rather than deferring: the corpse
## handoff must leave nothing valid behind this frame, or the fire sequence
## that still names an overlay casts a freed object when _exit_tree() tears it
## down (the cdc79b6 crash).
func detach_model() -> void:
	_release_overlays(true)
	_can_fire_while_moving.clear()


func dispose() -> void:
	detach_model()
	_unit = null


func can_fire_while_moving(weapon_index: int) -> bool:
	return bool(_can_fire_while_moving.get(weapon_index, false))


func player_for(weapon_index: int) -> AnimationPlayer:
	return _overlays.get(weapon_index) as AnimationPlayer


## Registers an overlay player for a weapon. Used by rebuild() for the players
## it synthesizes, and by tests/units/death_animation_run.gd to plant the
## freed-overlay case that once crashed the death handoff.
func adopt_overlay(weapon_index: int, player: AnimationPlayer) -> void:
	_overlays[weapon_index] = player


## Rebuilt whenever the model or the weapon set changes. Only a turret active
## in the unit's spawn-time state (always TRAVEL) can ever fire while moving;
## a combat-deploy unit's deployed turret is inactive here and immobile
## whenever it later becomes active, so it never needs an overlay bound to the
## wrong (travel-mode) clip.
func rebuild(turrets: Array, list_provider: Callable) -> void:
	# Deferred here, unlike detach_model(): a rebuild can run while the model
	# is mid-frame, and the outgoing players may still be playing.
	_release_overlays(false)
	_can_fire_while_moving.clear()
	var definition: Resource = _unit.unit_definition
	for turret in turrets:
		var weapon_index: int = turret.weapon_index()
		var bindings: Array[Dictionary] = list_provider.call(weapon_index)
		var compatible: bool = turret.has_independent_yaw() and not bindings.is_empty()
		var first_player: AnimationPlayer = null
		var names := {}
		for binding in bindings:
			var player := binding.get("player") as AnimationPlayer
			var name := StringName(binding.get("name", &""))
			if player == null or names.has(name) or (
				first_player != null and (
					player != first_player or player.root_node != first_player.root_node
				)
			):
				compatible = false
			if first_player == null:
				first_player = player
			names[name] = true
			if compatible and not ((definition != null and definition.can_fly) \
				or _fire_animation_is_turret_local(binding, turret)):
				compatible = false
		_can_fire_while_moving[weapon_index] = false
		if not compatible:
			continue
		var overlay := _create_overlay(bindings, turret)
		if overlay != null:
			adopt_overlay(weapon_index, overlay)
			_can_fire_while_moving[weapon_index] = true


func _release_overlays(immediate: bool) -> void:
	for overlay_value: Variant in _overlays.values():
		if not is_instance_valid(overlay_value) or not overlay_value is Node:
			continue
		var overlay := overlay_value as Node
		if immediate:
			overlay.free()
		else:
			overlay.queue_free()
	_overlays.clear()


func _fire_animation_is_turret_local(binding: Dictionary, turret) -> bool:
	var player := binding.get("player") as AnimationPlayer
	var animation_name := StringName(binding.get("name", &""))
	if player == null:
		return false
	var animation := player.get_animation(animation_name)
	if animation == null:
		return false
	for track in animation.get_track_count():
		if not AuthoredModelScript.track_changes(animation, track):
			continue
		var track_path := String(animation.track_get_path(track))
		if not track_path.ends_with(":transform"):
			continue
		var target_node := AuthoredModelScript.track_node(player, track_path)
		if target_node != null and not turret.owns_aim_branch(target_node):
			return false
	return true


func _create_overlay(bindings: Array[Dictionary], turret) -> AnimationPlayer:
	var source_player := bindings[0].get("player") as AnimationPlayer
	if source_player == null or source_player.get_parent() == null:
		return null
	var definition: Resource = _unit.unit_definition
	var overlay := AnimationPlayer.new()
	overlay.name = "WeaponFireOverlay_%d" % turret.weapon_index()
	overlay.root_node = source_player.root_node
	overlay.process_priority = _unit.process_priority - 1
	overlay.set_meta("combat_weapon_fire_overlay", true)
	source_player.get_parent().add_child(overlay)
	var library := AnimationLibrary.new()
	for binding in bindings:
		var animation_name := StringName(binding["name"])
		var source_animation := source_player.get_animation(animation_name)
		if source_animation == null:
			overlay.free()
			return null
		var animation := source_animation.duplicate(true) as Animation
		for track in range(animation.get_track_count() - 1, -1, -1):
			var track_path := String(animation.track_get_path(track))
			var target_node := AuthoredModelScript.track_node(source_player, track_path)
			var keep: bool = AuthoredModelScript.track_changes(animation, track) \
				and (
					(definition != null and definition.can_fly)
					or target_node == null
					or turret.owns_aim_branch(target_node)
				)
			if not keep:
				animation.remove_track(track)
		library.add_animation(animation_name, animation)
	overlay.add_animation_library(&"", library)
	return overlay
