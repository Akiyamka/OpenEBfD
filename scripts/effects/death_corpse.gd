class_name DeathCorpse
extends RigidBody3D

const AuthoredModelScript := preload("res://scripts/world/authored_model.gd")

## Throwaway node spawned by `Unit._begin_death_sequence()` the instant a unit
## dies (and, per the death-animation plan's §8, later reused for building
## destruction). Deliberately not under scripts/units/: it is not a unit and
## is shared across both callers. Its only job is to carry the already-
## instantiated model subtree the dying node handed off, play one death clip,
## optionally fall/tumble under gravity, and free itself once the clip (and,
## from a later pass, its death sound) finish.
##
## Not under the "units" group by construction: unit_command_controller.gd
## filters selection by that group and match_snapshot.gd serialises it: a
## corpse has no place in a save and must never become selectable.

const PlayerDataScript := preload("res://scripts/players/player_data.gd")
const DeathCorpseScene := preload("res://scenes/effects/death_corpse.tscn")
const DeathSoundPlayerScript := preload("res://scripts/audio/death_sound_player.gd")
const SoundEventScript := preload("res://scripts/audio/sound_event.gd")
const GeneratedVoiceManifest := preload("res://resources/audio/generated_voice_manifest.gd")

## The corpse's own free layer/mask (docs/... see death-animation plan §5):
## terrain = 1, units/buildings = 2, so bit 3 (value 4) is unclaimed. A
## terrain-only mask means projectiles (mask 3) and units (mask 0 at runtime)
## never test against a corpse at all — "fully ignored in collisions with
## other units" falls out for free rather than needing an exclusion list.
const COLLISION_LAYER := 4
const COLLISION_MASK := 1

## Simulated corpses freeze once asleep or after this timeout, whichever
## first — a corpse must not keep simulating physics for the rest of the
## match just because it landed somewhere that never quite settles.
const SETTLE_TIMEOUT_SECONDS := 2.0
const MAX_TUMBLE_ANGULAR_SPEED := 2.0
## A degenerate/absent mesh (or the corpse test's stand-in models) must not
## produce a zero-thickness collider on any axis.
const MIN_SHAPE_DIMENSION := 0.2

var owner_player_id := PlayerDataScript.NEUTRAL_PLAYER_ID

var _model: Node3D
var _collision_shape: CollisionShape3D
## Kept for tests/introspection: the AABB the box collider was actually fit
## to, in the corpse's own local space.
var _fitted_local_aabb := AABB()
var _death_animation_player: AnimationPlayer
var _death_clip: StringName = &""
var _animation_done := false
## How many sound layers are still outstanding — playing, or waiting on their
## authored start delay. A corpse can carry more than one layer (see
## AuthoredDeathVoice), so this is a count, not a flag: _maybe_free() waits for
## every layer before freeing the corpse — an explosion sample must not be cut
## off by a short death clip finishing first. Layers with no resolvable sample
## are never counted at all, so one bad layer can neither block the others nor
## keep the corpse alive forever.
var _pending_sounds := 0


## Entry point called by Unit (and later BuildingDeathStrategy) before the
## dying node frees itself. `model` must already be detached from its old
## parent (Unit.visual_root) with its local transform intact — the corpse
## reparents it as-is under `world_transform`. `momentum` is
## Vector3.ZERO for in-place deaths: no physics simulation runs at all in
## that case (see _configure_physics()).
static func spawn(
		world: Node,
		model: Node3D,
		world_transform: Transform3D,
		clip: StringName,
		voice_schedule: Array[Dictionary],
		momentum: Vector3,
		corpse_owner_player_id: int,
		start_sound_paths: Array[String] = [],
	) -> DeathCorpse:
	var corpse := DeathCorpseScene.instantiate() as DeathCorpse
	corpse.owner_player_id = corpse_owner_player_id
	# Parent first, then stamp the global transform: assigning `.transform`
	# before the node is inside the tree would only equal the intended world
	# transform if `world` itself sits at the scene origin.
	world.add_child(corpse)
	corpse.global_transform = world_transform
	corpse._adopt_model(model)
	corpse._play_death_clip(clip)
	corpse._configure_physics(momentum)
	corpse._configure_sounds(voice_schedule)
	corpse._configure_start_sound(start_sound_paths)
	corpse._maybe_free()
	return corpse


func _adopt_model(model: Node3D) -> void:
	_model = model
	add_child(model)
	_fit_collision_shape()


## Sizes the corpse's collider from the adopted model's own mesh geometry
## rather than a fixed constant: a fixed sphere would make a large vehicle
## corpse sink into (or hover above) the terrain, and — worse — makes any
## simulated corpse roll away like a ball once it lands, which reads as a
## bug rather than a body/wreck coming to rest. Mirrors the AABB-over-meshes
## approach Unit._selection_bounds()/_mesh_instances() already use for
## combat_aim_position(), just computed in the corpse's own local frame
## since the CollisionShape3D here is a sibling of the model, not a child
## of it.
func _fit_collision_shape() -> void:
	_collision_shape = get_node_or_null("CollisionShape3D") as CollisionShape3D
	if _collision_shape == null:
		return
	_fitted_local_aabb = _model_local_aabb()
	var box := BoxShape3D.new()
	box.size = Vector3(
		maxf(_fitted_local_aabb.size.x, MIN_SHAPE_DIMENSION),
		maxf(_fitted_local_aabb.size.y, MIN_SHAPE_DIMENSION),
		maxf(_fitted_local_aabb.size.z, MIN_SHAPE_DIMENSION),
	)
	_collision_shape.shape = box
	_collision_shape.transform = Transform3D(Basis.IDENTITY, _fitted_local_aabb.get_center())


func _model_local_aabb() -> AABB:
	var meshes: Array[MeshInstance3D] = []
	_collect_mesh_instances(_model, meshes)
	var bounds := AABB()
	var has_bounds := false
	for mesh_instance in meshes:
		for corner in _aabb_corners(mesh_instance.get_aabb()):
			var point := to_local(mesh_instance.to_global(corner))
			if has_bounds:
				bounds = bounds.expand(point)
			else:
				bounds = AABB(point, Vector3.ZERO)
				has_bounds = true
	if has_bounds:
		return bounds
	# No mesh geometry at all (a bare test stand-in, or a stripped model) —
	# a small default box beats a zero-size collider.
	return AABB(Vector3(-0.5, -0.25, -0.5), Vector3(1.0, 0.5, 1.0))


func _collect_mesh_instances(node: Node, result: Array[MeshInstance3D]) -> void:
	if node is MeshInstance3D:
		result.append(node)
	for child in node.get_children():
		_collect_mesh_instances(child, result)


func _aabb_corners(bounds: AABB) -> Array[Vector3]:
	var corners: Array[Vector3] = []
	for x in [bounds.position.x, bounds.end.x]:
		for y in [bounds.position.y, bounds.end.y]:
			for z in [bounds.position.z, bounds.end.z]:
				corners.append(Vector3(x, y, z))
	return corners


func _play_death_clip(clip: StringName) -> void:
	_death_clip = clip
	var players := _collect_animation_players()
	for player in players:
		# Stop whatever the dying unit's idle/movement logic left running and
		# drop the process-order priority Unit imposed
		# (_prioritize_animations_before_unit_logic): that ordering existed
		# only to keep combat turret transforms authoritative over Unit's own
		# per-frame logic, which no longer runs here.
		player.stop()
		player.process_priority = 0
	for player in players:
		if player.has_animation(clip):
			_death_animation_player = player
			break
	if _death_animation_player == null:
		_animation_done = true
		return
	var animation := _death_animation_player.get_animation(clip)
	if animation != null:
		animation.loop_mode = Animation.LOOP_NONE
	# Unit._prepare_model_for_corpse() explicitly disconnects every
	# connection it made onto this subtree before handing it off (see
	# Unit._sever_connections_into()), so this is guaranteed to be the only
	# listener left — not merely assumed to be, since queue_free() alone
	# would not have removed it until the end of this same frame.
	_death_animation_player.animation_finished.connect(_on_death_animation_finished)
	_death_animation_player.play(clip)


func _collect_animation_players() -> Array[AnimationPlayer]:
	return AuthoredModelScript.animation_players(_model)


func _on_death_animation_finished(animation_name: StringName) -> void:
	if animation_name != _death_clip:
		return
	_animation_done = true
	_maybe_free()


func _configure_physics(momentum: Vector3) -> void:
	collision_layer = COLLISION_LAYER
	collision_mask = COLLISION_MASK
	if momentum.is_zero_approx():
		# In-place death clips must not be simulated at all: gravity pulling
		# the body while the animation drives the skeleton is exactly the
		# terrain-triangle-edge jitter Unit avoids by disabling its own
		# terrain collision (see the collision_mask comment in Unit._ready()). A
		# frozen corpse is the "almost logic-free placeholder" this design
		# wants; the RigidBody3D root is simply carried along unused.
		freeze = true
		return
	freeze = false
	linear_velocity = momentum
	angular_velocity = Vector3(
		randf_range(-MAX_TUMBLE_ANGULAR_SPEED, MAX_TUMBLE_ANGULAR_SPEED),
		randf_range(-MAX_TUMBLE_ANGULAR_SPEED, MAX_TUMBLE_ANGULAR_SPEED),
		randf_range(-MAX_TUMBLE_ANGULAR_SPEED, MAX_TUMBLE_ANGULAR_SPEED),
	)
	sleeping_state_changed.connect(_on_sleeping_state_changed)
	if is_inside_tree():
		get_tree().create_timer(SETTLE_TIMEOUT_SECONDS).timeout.connect(_on_settle_timeout)


func _on_sleeping_state_changed() -> void:
	if sleeping:
		freeze = true


func _on_settle_timeout() -> void:
	freeze = true


## Looks up `sound_event_id` (already one of the ids AuthoredDeathVoice resolved
## off the model's FX events) in the generated `DEATH_EVENT_PATHS` manifest.
## Keyed case-insensitively: the manifest keys by the id casefolded
## (tools/generate_voice_feedback.py), since the surviving section's own casing
## depends on which source SFX file last defined it under parse_sources()'s
## casefold-keyed, last-file-wins merge.
func _resolve_sound_path(sound_event_id: StringName) -> String:
	if sound_event_id == &"":
		return ""
	var key := StringName(String(sound_event_id).to_lower())
	return String(GeneratedVoiceManifest.DEATH_EVENT_PATHS.get(key, ""))


## One throwaway DeathSoundPlayer per resolved layer, each started at the frame
## its model authored it on (`delay` seconds into the clip, see
## AuthoredDeathVoice) rather than all at once on the killing blow — a burning
## man must not scream before he is alight.
##
## Every layer is counted up front, delayed ones included: _maybe_free() runs
## the moment spawn() returns, so a layer that has not started playing yet would
## otherwise let the corpse free itself out from under its own scream.
func _configure_sounds(voice_schedule: Array[Dictionary]) -> void:
	for entry in voice_schedule:
		var sample_path := _resolve_sound_path(
			StringName(entry.get("event_id", &""))
		)
		if sample_path.is_empty():
			continue
		var event := load(sample_path) as SoundEvent
		if event == null or event.sample_paths.is_empty():
			# A generated event with no samples (missing from the converted WAV
			# archive) must degrade to silence, not to a corpse that never frees.
			continue
		_pending_sounds += 1
		var delay := float(entry.get("delay", 0.0))
		if delay <= 0.0 or not is_inside_tree():
			_start_sound_event(event)
			continue
		get_tree().create_timer(delay).timeout.connect(
			_start_sound_event.bind(event)
		)


func _start_sound_event(event: SoundEventScript) -> void:
	# The timer outlives a corpse freed for any other reason (the match ending,
	# the scene changing); its callback must not resurrect one.
	if not is_instance_valid(self) or is_queued_for_deletion():
		return
	var player := DeathSoundPlayerScript.new()
	add_child(player)
	player.sound_finished.connect(_on_sound_finished)
	player.play_event(event)


## The faction/self-destruct "start of animation" extra layer (see
## VehicleDeathStrategy.death_start_sound_paths / InfantryDeathStrategy's
## HKFlamer case): one random direct-WAV pick, played immediately alongside
## the death clip rather than through GeneratedVoiceManifest. Counted in
## _pending_sounds exactly like _configure_sounds's layers, so this corpse
## doesn't free itself out from under its own explosion sample.
func _configure_start_sound(paths: Array[String]) -> void:
	if paths.is_empty():
		return
	var path: String = paths[randi() % paths.size()]
	var stream := load(path) as AudioStream
	if stream == null:
		return
	_pending_sounds += 1
	var player := DeathSoundPlayerScript.new()
	add_child(player)
	player.sound_finished.connect(_on_sound_finished)
	player.play_stream(stream)


func _on_sound_finished() -> void:
	_pending_sounds = maxi(_pending_sounds - 1, 0)
	_maybe_free()


func _maybe_free() -> void:
	if _animation_done and _pending_sounds == 0:
		queue_free()
