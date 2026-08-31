class_name AuthoredFireController
extends RefCounted

const FireRequestScript := preload("res://scripts/combat/fire_request.gd")
const CombatRulesScript := preload("res://scripts/combat/combat_rules.gd")
const AuthoredReloadSoundScript := preload(
	"res://scripts/combat/authored_reload_sound.gd"
)
const SfxSectionCatalogScript := preload("res://scripts/audio/sfx_section_catalog.gd")

signal weapon_fired(projectiles: Array, target: Variant, weapon_index: int)

const BAKED_MODEL_FRAMES_PER_SECOND := 20.0
const RULE_COMBAT_TICKS_PER_SECOND := CombatRulesScript.TICKS_PER_SECOND
const FIRE_ANIMATION_SPEED_SCALE := (
	RULE_COMBAT_TICKS_PER_SECOND / BAKED_MODEL_FRAMES_PER_SECOND
)
const FIRE_ANIMATION_PREFIX := "Fire_"
const FIRE_EVENT_EPSILON := 0.0001

var _source: Object
var _turret
var _model_root: Node3D
var _sequences: Dictionary = {}


static func authored_fire_shot_times(
	player: AnimationPlayer,
	animation: Animation,
	turret,
	model_root: Node,
	animation_name: StringName = &""
	) -> Array[Dictionary]:
	if animation_name.is_empty():
		for candidate_name: StringName in player.get_animation_list():
			if player.get_animation(candidate_name) == animation:
				animation_name = candidate_name
				break
	var controller := AuthoredFireController.new()
	controller._turret = turret
	controller._model_root = model_root as Node3D
	return controller._authored_fire_shot_times(
		player, animation, animation_name
	)


static func xbf_fire_shot_times(
	animation_name: StringName,
	animation: Animation,
	turret,
	model_root: Node
	) -> Array[Dictionary]:
	var controller := AuthoredFireController.new()
	controller._turret = turret
	controller._model_root = model_root as Node3D
	return controller._xbf_fire_shot_times(animation_name, animation)


func start_sequence(
	sequences: Dictionary,
	turret,
	target: Variant,
	player: AnimationPlayer,
	animation_name: StringName,
	animation: Animation,
	shot_times: Array[Dictionary],
	blocking: bool,
	reload_after_animation: bool,
	restore_aim_poses: Callable = Callable(),
	sound_times: Array[Dictionary] = []
	) -> bool:
	var weapon_index: int = turret.weapon_index()
	if sequences.has(weapon_index) or animation == null or animation.length <= 0.0:
		return false
	var target_state := _encoded_target(target)
	if target_state.is_empty():
		return false
	sequences[weapon_index] = {
		"turret": turret,
		"target": target_state,
		"player": player,
		"animation": animation_name,
		"duration": animation.length,
		"elapsed": 0.0,
		"shot_times": shot_times,
		"next_shot": 0,
		"shots_emitted": 0,
		"blocking": blocking,
		# Kept apart from `shot_times` on purpose: a reload is not a shot, and
		# folding the two together would corrupt everything that counts shot
		# events -- `_fire_sequence_has_multiple_shots`, the continuous-bullet
		# `damage_scale` split below, and the `burst_shot_count` validation in
		# `_xbf_fire_shot_times`.
		"sound_times": sound_times,
		"next_sound": 0,
	}
	if not reload_after_animation:
		turret.begin_reload()
	if player != null and player.has_animation(animation_name):
		player.speed_scale = FIRE_ANIMATION_SPEED_SCALE
		player.stop(true)
		player.play(animation_name)
		_apply_animation_start_transforms(player, animation_name)
		if restore_aim_poses.is_valid():
			restore_aim_poses.call()
		else:
			turret.restore_aim_pose()
	turret.start_authored_fire_fx(
		animation_name, null, FIRE_ANIMATION_SPEED_SCALE
	)
	return true


func advance_sequences(
	sequences: Dictionary,
	delta: float,
	source: Object,
	reload_after_animation: bool
	) -> bool:
	var restore_idle := false
	for weapon_index: Variant in sequences.keys():
		if not sequences.has(weapon_index):
			continue
		var state: Dictionary = sequences[weapon_index]
		var elapsed := minf(
			float(state.get("elapsed", 0.0))
				+ maxf(delta, 0.0) * FIRE_ANIMATION_SPEED_SCALE,
			float(state.get("duration", 0.0))
		)
		state["elapsed"] = elapsed
		var shot_times: Array = state.get("shot_times", [])
		var next_shot := int(state.get("next_shot", 0))
		var turret = state.get("turret")
		var target: Variant = _decoded_target(state.get("target", {}))
		var damage_scale := 1.0
		if bool(turret.is_continuous_bullet()) and not shot_times.is_empty():
			damage_scale = 1.0 / float(shot_times.size())
		while (
			next_shot < shot_times.size()
			and float((shot_times[next_shot] as Dictionary)["time"])
				<= elapsed + FIRE_EVENT_EPSILON
		):
			var shot: Dictionary = shot_times[next_shot]
			next_shot += 1
			if target == null:
				continue
			var projectiles: Array = turret.try_fire_at(
				FireRequestScript.authored(
					target, source, damage_scale, int(shot.get("muzzle", -1))
				)
			)
			if projectiles.is_empty():
				continue
			state["shots_emitted"] = int(state.get("shots_emitted", 0)) \
				+ projectiles.size()
			weapon_fired.emit(projectiles, target, int(weapon_index))
		state["next_shot"] = next_shot
		state["next_sound"] = _play_crossed_sounds(state, elapsed, source)
		sequences[weapon_index] = state
		if elapsed + FIRE_EVENT_EPSILON >= float(state.get("duration", 0.0)):
			restore_idle = finish_sequence(
				sequences, int(weapon_index), reload_after_animation
			) or restore_idle
	return restore_idle


## Plays every authored sound the clip crossed since the previous tick and
## returns the new `next_sound` cursor. Independent of the shot loop above,
## including its `target == null` skip: a man whose target died mid-clip still
## racks the bolt.
##
## The simulation integrator reaches here when its authored sequence lands on
## `duration`. Every authored reload sits 42-52 frames into its clip, near the
## end. A burst cut short is the opposite case and stays silent: cancellation
## goes through `cancel_sequences()` -> `_stop_sequence()`, which never comes
## past here.
func _play_crossed_sounds(
	state: Dictionary, elapsed: float, source: Object
	) -> int:
	var sound_times: Array = state.get("sound_times", [])
	var next_sound := int(state.get("next_sound", 0))
	while (
		next_sound < sound_times.size()
		and float((sound_times[next_sound] as Dictionary)["time"])
			<= elapsed + FIRE_EVENT_EPSILON
	):
		var entry: Dictionary = sound_times[next_sound]
		next_sound += 1
		_play_authored_sound(source, StringName(entry.get("section", &"")))
	return next_sound


## Parented to the source's parent rather than the source: a reload that starts
## on the frame the unit dies should finish playing rather than be freed with
## it, exactly like UnitMovementSounds._play() and the corpse's death sounds.
func _play_authored_sound(source: Object, section: StringName) -> void:
	if section.is_empty() or not is_instance_valid(source):
		return
	var node := source as Node3D
	if node == null or not node.is_inside_tree():
		return
	SfxSectionCatalogScript.play_at(
		node.get_parent(), node.global_position, section
	)


func finish_sequence(
	sequences: Dictionary, weapon_index: int, reload_after_animation: bool
	) -> bool:
	if not sequences.has(weapon_index):
		return false
	var state: Dictionary = sequences[weapon_index]
	sequences.erase(weapon_index)
	_stop_sequence(state, reload_after_animation)
	return bool(state.get("blocking", false))


func cancel_sequences(
	sequences: Dictionary,
	reload_after_animation: bool,
	blocking_only := false,
	commit_reload := true
	) -> bool:
	var restore_idle := false
	for weapon_index: Variant in sequences.keys():
		var state: Dictionary = sequences[weapon_index]
		if blocking_only and not bool(state.get("blocking", false)):
			continue
		restore_idle = bool(state.get("blocking", false)) or restore_idle
		# Erase before stopping, matching finish_sequence(): _stop_sequence()
		# settles the authored clip on its final frame, and an AnimationPlayer
		# signal raised from that must not find this sequence still registered.
		sequences.erase(weapon_index)
		_stop_sequence(state, reload_after_animation and commit_reload)
	return restore_idle


func has_blocking_sequence(sequences: Dictionary) -> bool:
	for state_value: Variant in sequences.values():
		if bool((state_value as Dictionary).get("blocking", false)):
			return true
	return false


## `stop(true)` deliberately keeps the pose the clip last wrote (see
## Unit.play_animation_from_start), which is correct for a burst that ran to
## the end -- an authored Fire clip returns every node it keys to its rest pose
## on its final frame. A burst cut short (Stop during the burst, a target
## dying, a move order) freezes that same pose wherever it happened to be, and
## on a gun turret that is mid-muzzle-flash: ATPillbox scales `_bigflash1` by
## ~40x over its rest transform and HKGunTurret scales each `_bigflashNN` by
## ~60x, with the barrels' AttachmentFX particles still emitting. Nothing
## writes those nodes again -- a stationary defensive building runs no idle
## clip on its model player -- so the flash stays stuck on the barrels and
## swings around with the turret as it recenters. Settling the clip on its
## final frame first leaves exactly the pose a completed burst leaves.
func _stop_sequence(state: Dictionary, reload_after_animation: bool) -> void:
	var player_value: Variant = state.get("player")
	if is_instance_valid(player_value) and player_value is AnimationPlayer:
		var player := player_value as AnimationPlayer
		var animation_name := StringName(state.get("animation", &""))
		if not animation_name.is_empty() \
		and player.current_animation == animation_name:
			player.seek(float(state.get("duration", 0.0)), true)
		player.stop(true)
	var turret = state.get("turret")
	if turret != null:
		turret.cancel_authored_fire_fx()
		# The clip's final frame keys the aim pivots back to their authored
		# straight-ahead pose, so the combat-owned angles have to be reapplied
		# before the frame renders.
		turret.restore_aim_pose()
	if reload_after_animation \
	and int(state.get("shots_emitted", 0)) > 0 and turret != null:
		turret.begin_reload()


func configure(source: Object, turret, model_root: Node3D) -> void:
	cancel()
	_source = source
	_turret = turret
	_model_root = model_root


func is_active() -> bool:
	return not _sequences.is_empty()


## Starts the active model's authored Fire clip and commits all projectile
## events in it. Returns false when no clip exists or the reload is not ready;
## callers may use the ordinary one-shot turret fallback only when no clip
## exists (`has_fire_animation` is false).
func try_start(target: Variant) -> bool:
	if is_active() or _turret == null:
		return false
	var binding := _fire_animation_binding()
	if binding.is_empty():
		return false
	var is_continuous: bool = bool(_turret.is_continuous_bullet())
	var starting_new_burst := false
	var ready := false
	if is_continuous and bool(_turret.continuous_burst_active()):
		ready = true
	else:
		ready = bool(_turret.is_ready())
		starting_new_burst = is_continuous and ready
	if not ready:
		return false
	var player := binding["player"] as AnimationPlayer
	var animation_name := StringName(binding["name"])
	var animation := player.get_animation(animation_name)
	if animation == null or animation.length <= 0.0:
		return false
	# See `_fire_sequence_has_multiple_shots` in unit_combat.gd: only a clip
	# with more than one authored shot event is a genuine sustained stream
	# worth replaying for a burst window; a single-shot `Continuous` bullet
	# just fires and reloads normally.
	var shot_times := _authored_fire_shot_times(player, animation, animation_name)
	var started := start_sequence(
		_sequences,
		_turret,
		target,
		player,
		animation_name,
		animation,
		shot_times,
		false,
		false,
		Callable(),
		AuthoredReloadSoundScript.schedule(_model_root, animation_name)
	)
	if not started:
		return false
	if starting_new_burst:
		_turret.begin_continuous_burst(shot_times.size() > 1)
	return true


func has_fire_animation() -> bool:
	return not _fire_animation_binding().is_empty()


func advance(delta: float) -> void:
	advance_sequences(_sequences, delta, _source, false)


func cancel() -> void:
	cancel_sequences(_sequences, false)


func _fire_animation_binding() -> Dictionary:
	if _model_root == null or not is_instance_valid(_model_root) or _turret == null:
		return {}
	var preferred := StringName(
		"%s%d" % [FIRE_ANIMATION_PREFIX, _turret.weapon_index()]
	)
	var fallback_candidates: Array[StringName] = [preferred, &"Fire"]
	if _turret.weapon_index() != 0:
		fallback_candidates.append(&"Fire_0")
	for node in _model_root.find_children("*", "AnimationPlayer", true, false):
		var player := node as AnimationPlayer
		for animation_name in fallback_candidates:
			if player.has_animation(animation_name):
				return {"player": player, "name": animation_name}
	return {}


func _apply_animation_start_transforms(
	player: AnimationPlayer, animation_name: StringName
	) -> void:
	var animation := player.get_animation(animation_name)
	if animation == null:
		return
	for track in animation.get_track_count():
		if animation.track_get_type(track) != Animation.TYPE_VALUE \
		or not String(animation.track_get_path(track)).ends_with(":transform") \
		or animation.track_get_key_count(track) == 0 \
		or animation.track_get_key_time(track, 0) > FIRE_EVENT_EPSILON:
			continue
		var target := _animation_track_node(
			player, String(animation.track_get_path(track))
		) as Node3D
		var value: Variant = animation.track_get_key_value(track, 0)
		if target != null and value is Transform3D:
			target.transform = value as Transform3D


func _animation_track_node(
	player: AnimationPlayer, track_path: String
	) -> Node:
	if player == null:
		return null
	var animation_root := player.get_node_or_null(player.root_node)
	if animation_root == null:
		return null
	var separator := track_path.find(":")
	var node_path := track_path.substr(0, separator) \
		if separator >= 0 else track_path
	return animation_root.get_node_or_null(NodePath(node_path))


func _authored_fire_shot_times(
	player: AnimationPlayer,
	animation: Animation,
	animation_name: StringName
	) -> Array[Dictionary]:
	var xbf_events := _xbf_fire_shot_times(animation_name, animation)
	if not xbf_events.is_empty():
		return xbf_events
	var configured_burst := _configured_burst_shot_times(animation)
	if not configured_burst.is_empty():
		return configured_burst
	var fallback: Array[Dictionary] = [
		{"time": minf(1.0 / BAKED_MODEL_FRAMES_PER_SECOND, animation.length), "muzzle": -1}
	]
	if _turret.muzzle_count() <= 1:
		return fallback
	var animation_root := player.get_node_or_null(player.root_node)
	if animation_root == null:
		return fallback
	var events: Array[Dictionary] = []
	var used_tracks: Dictionary = {}
	for emission: Dictionary in _turret.emission_points():
		var muzzle := emission.get("node") as Node
		if muzzle == null:
			return fallback
		var current := muzzle.get_parent()
		var found := false
		while current != null and (
			current == animation_root or animation_root.is_ancestor_of(current)
		):
			var relative_path := animation_root.get_path_to(current)
			var track_path := NodePath("%s:transform" % String(relative_path))
			var track := animation.find_track(track_path, Animation.TYPE_VALUE)
			if track >= 0:
				var peak := _animation_transform_peak(animation, track)
				if float(peak.get("score", 0.0)) > FIRE_EVENT_EPSILON:
					var track_key := String(track_path)
					if used_tracks.has(track_key):
						return fallback
					used_tracks[track_key] = true
					events.append({
						"muzzle": int(emission.get("index", events.size())),
						"time": clampf(
							float(peak["time"]), 0.0, animation.length
						),
					})
					found = true
					break
			if current == animation_root:
				break
			current = current.get_parent()
		if not found:
			return fallback
	if events.size() != _turret.muzzle_count():
		return fallback
	events.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return float(a["time"]) < float(b["time"])
	)
	return events


## Every type-10 launch event an authored Fire clip's XBF data carries names
## the physical muzzle (its `value` payload) whose bone actually peaks at that
## frame -- the visible barrel order the animation shows, which need not match
## the muzzle markers' plain numeric >>N naming. Validated against the bound
## turret's own muzzle_count() before trusting it, since `value` is not
## documented and other event categories (e.g. locomotion footstep events)
## reuse the same field for unrelated data; an out-of-range value anywhere in
## the clip discards muzzle info for the whole result rather than guessing.
func _xbf_fire_shot_times(
	animation_name: StringName, animation: Animation
	) -> Array[Dictionary]:
	if animation_name.is_empty() or _model_root == null:
		return []
	var motion_root := find_xbf_motion_root(_model_root)
	if motion_root == null \
	or not bool(motion_root.get_meta("xbf_fx_events_complete", false)):
		return []
	var source_entry := {}
	for entry_value: Variant in motion_root.get_meta(
		"xbf_animation_entries", []
	):
		var entry := entry_value as Dictionary
		var converted_name := String(
			entry.get("name", "")
		).strip_edges().replace(" ", "_")
		if converted_name == String(animation_name):
			source_entry = entry
			break
	if source_entry.is_empty():
		return []
	var start_frame := int(source_entry.get("start_frame", -1))
	var end_frame := int(source_entry.get("end_frame", -1))
	if start_frame < 0 or end_frame < start_frame:
		return []
	var muzzle_count: int = _turret.muzzle_count()
	var muzzles_trustworthy := true
	var result: Array[Dictionary] = []
	for event_value: Variant in motion_root.get_meta("xbf_fx_events", []):
		var event := event_value as Dictionary
		var frame := int(event.get("frame", -1))
		if int(event.get("type", -1)) == 10 \
		and frame >= start_frame and frame <= end_frame:
			var muzzle := int(event.get("value", -1))
			if muzzle < 0 or muzzle >= muzzle_count:
				muzzles_trustworthy = false
			result.append({
				"time": clampf(
					float(frame - start_frame) / BAKED_MODEL_FRAMES_PER_SECOND,
					0.0,
					animation.length
				),
				"muzzle": muzzle,
			})
	if not muzzles_trustworthy:
		for shot in result:
			shot["muzzle"] = -1
	if (
		result.size() == 1
		and _turret.bullet_config != null
		and bool(_turret.bullet_config.continuous)
	):
		var first_shot_frame := int(round(
			float(result[0]["time"]) * BAKED_MODEL_FRAMES_PER_SECOND
		)) + start_frame
		var continuous_result := _xbf_continuous_fire_shot_times(
			motion_root,
			start_frame,
			end_frame,
			animation.length,
			first_shot_frame,
			int(result[0]["muzzle"])
		)
		if continuous_result.size() > 1:
			return continuous_result
	if _turret.firing_config != null:
		var configured_count := int(
			_turret.firing_config.burst_shot_count
		)
		if configured_count > 0 and result.size() != configured_count:
			return []
	return result


func _xbf_continuous_fire_shot_times(
	motion_root: Node,
	clip_start: int,
	clip_end: int,
	animation_length: float,
	first_shot_frame: int,
	muzzle: int
	) -> Array[Dictionary]:
	var stream_stop_frame := first_shot_frame + 1
	var events := motion_root.get_meta("xbf_fx_events", []) as Array
	for start_value: Variant in events:
		var start_event := start_value as Dictionary
		if String(start_event.get("action", "")) != "start":
			continue
		var start_frame := int(start_event.get("frame", -1))
		if start_frame < clip_start or start_frame > first_shot_frame:
			continue
		var attachment := String(
			start_event.get("attachment", "")
		).to_lower()
		if not attachment.begins_with(">>") and not attachment.contains("gun"):
			continue
		var bank_id := String(start_event.get("bank_id", ""))
		for stop_value: Variant in events:
			var stop_event := stop_value as Dictionary
			if (
				String(stop_event.get("action", "")) != "stop"
				or String(stop_event.get("bank_id", "")) != bank_id
				or String(stop_event.get("attachment", "")).nocasecmp_to(
					String(start_event.get("attachment", ""))
				) != 0
			):
				continue
			var stop_frame := int(stop_event.get("frame", -1))
			if stop_frame > first_shot_frame and stop_frame <= clip_end:
				stream_stop_frame = maxi(stream_stop_frame, stop_frame)
				break
	var result: Array[Dictionary] = []
	for frame in range(first_shot_frame, stream_stop_frame):
		result.append({
			"time": clampf(
				float(frame - clip_start) / BAKED_MODEL_FRAMES_PER_SECOND,
				0.0,
				animation_length
			),
			"muzzle": muzzle,
		})
	return result


func _configured_burst_shot_times(
	animation: Animation
	) -> Array[Dictionary]:
	if _turret.firing_config == null:
		return []
	var count := int(_turret.firing_config.burst_shot_count)
	if count <= 0:
		return []
	var first_shot_time := minf(
		1.0 / BAKED_MODEL_FRAMES_PER_SECOND, animation.length
	)
	var interval_seconds := maxf(
		float(_turret.firing_config.burst_interval_ticks), 0.0
	) / RULE_COMBAT_TICKS_PER_SECOND
	var result: Array[Dictionary] = []
	for index in count:
		result.append({
			"time": minf(
				first_shot_time + float(index) * interval_seconds,
				animation.length
			),
			"muzzle": -1,
		})
	return result


func _animation_transform_peak(
	animation: Animation, track: int
	) -> Dictionary:
	if animation.track_get_key_count(track) <= 1:
		return {}
	var rest: Variant = animation.track_get_key_value(track, 0)
	if not rest is Transform3D:
		return {}
	var peak_score := 0.0
	var peak_time := 0.0
	for key_index in animation.track_get_key_count(track):
		var value: Variant = animation.track_get_key_value(track, key_index)
		if not value is Transform3D:
			continue
		var score := _transform_difference(
			rest as Transform3D, value as Transform3D
		)
		if score > peak_score:
			peak_score = score
			peak_time = animation.track_get_key_time(track, key_index)
	return {"score": peak_score, "time": peak_time}


func _transform_difference(a: Transform3D, b: Transform3D) -> float:
	var result := a.origin.distance_to(b.origin)
	result += a.basis.get_scale().distance_to(b.basis.get_scale())
	var relative_basis := (
		a.basis.orthonormalized().inverse()
		* b.basis.orthonormalized()
	)
	result += absf(
		relative_basis.get_rotation_quaternion().get_angle()
	)
	return result


static func find_xbf_motion_root(node: Node) -> Node:
	if node.has_meta("xbf_animation_entries") and node.has_meta("xbf_fx_events"):
		return node
	for child in node.get_children():
		var found := find_xbf_motion_root(child)
		if found != null:
			return found
	return null


func _encoded_target(target: Variant) -> Dictionary:
	if target is Vector3:
		return {"is_ground": true, "ground": target}
	if target is Object and is_instance_valid(target):
		return {"is_ground": false, "ref": weakref(target as Object)}
	return {}


func _decoded_target(state: Variant) -> Variant:
	if not state is Dictionary or (state as Dictionary).is_empty():
		return null
	if bool((state as Dictionary).get("is_ground", false)):
		return (state as Dictionary).get("ground", Vector3.INF)
	var target_ref := (state as Dictionary).get("ref") as WeakRef
	return target_ref.get_ref() if target_ref != null else null
