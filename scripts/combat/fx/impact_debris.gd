class_name ImpactDebris
extends RefCounted

## The hand-built particle rig behind the two authored emitter effects.
##
## Most ExplosionType XBFs draw themselves. ShellHit and MissileHit do not:
## their models are invisible `#bing` anchor cubes whose animation drives an FX
## bank, so what the player actually sees -- the burst billboard, the shrapnel
## spray, the flash of light -- has to be built here from the source texture
## sequences.
##
## The two effects differ in exactly one piece, so they are a table of pieces
## rather than a subclass or a boolean: MissileHit's RocketDetonation adds an
## expanding ring to the same spray.
##
## Nodes are parented to the CombatImpactEffect that owns this, and die with
## it; the tweens are created on the particles themselves.

const AuthoredFxBankScript := preload("res://scripts/combat/fx/authored_fx_bank.gd")

const BURST := &"burst"
const SPRAY := &"spray"
const SHRAPNEL := &"shrapnel"
const RING := &"ring"
const LIGHT := &"light"

const BURST_SEQUENCE := "!%Bru"
const BURST_FRAME_COUNT := 21
const BURST_SIZE := 2.0
const BURST_DURATION := 1.05
const BURST_SMOKE_FIRST_FRAME := 2
const BURST_SMOKE_OPACITY := 0.55
const BURST_MARKER := "?#bigbing~~1"

## DeviateHit (ORDeviator, ORGasTurret) and DevImpact (HKDevastator's plasma,
## layered with ShellHit) are marker-only rigs like ShellHit/MissileHit but
## carry their own marker names and texture sequences, so their burst pieces
## cannot reuse the BURST_* constants above. Frame timing follows the same
## ~0.05s/frame cadence as BURST_DURATION/BURST_FRAME_COUNT.
##
## DeviateHit authors two banks on ?#bigbing~~0/?#bigbing2: !cexp (the same
## puff shape MongooseLaunchSmoke uses, here bank-tinted dark green --
## int_parameters_7_11=[0,128,0,...], the same field
## CombatTurretFx._fx_bank_material() reads for muzzle particles) and !sess
## (the same puff shape, tinted a brighter green [0,180,0,...]). Only the
## !cexp piece is built: confirmed in-game, its burst shape reads as the gas
## detonation once tinted, while !sess's swirl duplicated it and read as
## redundant. The ?#bigbing2/!sess bank is left unused.
const DEVIATE_BURST_SEQUENCE := "!cexp"
const DEVIATE_BURST_MARKER := "?#bigbing~~0"
const DEVIATE_BURST_FRAME_COUNT := 16
const DEVIATE_BURST_SIZE := 10.0
const DEVIATE_BURST_DURATION := 0.8
const DEVIATE_BURST_TINT := Color(0.0, 128.0 / 255.0, 0.0)

## DevImpact's #splat bank authors !sm (the same puff shape as the Chemical
## Trooper's poison spray) tinted a pale blue -- int_parameters_7_11=[200,200,255,...].
## Unlike the burst rigs it authors motion rather than one billboard riding a
## marker: float_parameters_4_6=[5.0, 0.0, 32.0] is speed 5.0 with NO gravity,
## float_parameters_12_14[0]=-3.0 is the speed variation, and the #splat events
## emit across frames 0-10 -- an expanding cloud. Source speed converts to world
## the way CombatTurretFx does, `speed * world_scale * 20`, and world_scale here
## is 2.0/32 = 1/16, so 2.0..8.0 source becomes 2.5..10.0 world units/second.
const DEV_IMPACT_SEQUENCE := "!sm"
const DEV_IMPACT_MARKER := "#splat"
const DEV_IMPACT_FRAME_COUNT := 11
const DEV_IMPACT_SIZE := 2.0
const DEV_IMPACT_DURATION := 0.55
const DEV_IMPACT_TINT := Color(200.0 / 255.0, 200.0 / 255.0, 1.0)
const DEV_IMPACT_COUNT := 16
const DEV_IMPACT_SPEED_MIN := 2.5
const DEV_IMPACT_SPEED_MAX := 10.0
## The authored cloud is radial; this keeps it from being a flat disc without
## turning it into a fountain the zero-gravity bank would never pull back down.
const DEV_IMPACT_RISE_FRACTION := 0.35

## Which pieces each authored emitter effect is made of. An ExplosionType that
## is not listed renders itself and needs nothing from here.
const PIECES := {
	&"ShellHit": [
		{"kind": BURST, "marker": BURST_MARKER, "sequence": BURST_SEQUENCE,
			"frame_count": BURST_FRAME_COUNT, "size": BURST_SIZE, "duration": BURST_DURATION,
			"smoke_first_frame": BURST_SMOKE_FIRST_FRAME, "smoke_opacity": BURST_SMOKE_OPACITY},
		{"kind": SHRAPNEL},
		{"kind": LIGHT},
	],
	&"MissileHit": [
		{"kind": BURST, "marker": BURST_MARKER, "sequence": BURST_SEQUENCE,
			"frame_count": BURST_FRAME_COUNT, "size": BURST_SIZE, "duration": BURST_DURATION,
			"smoke_first_frame": BURST_SMOKE_FIRST_FRAME, "smoke_opacity": BURST_SMOKE_OPACITY},
		{"kind": SHRAPNEL},
		{"kind": RING},
		{"kind": LIGHT},
	],
	&"DeviateHit": [
		{"kind": BURST, "marker": DEVIATE_BURST_MARKER, "sequence": DEVIATE_BURST_SEQUENCE,
			"frame_count": DEVIATE_BURST_FRAME_COUNT, "size": DEVIATE_BURST_SIZE,
			"duration": DEVIATE_BURST_DURATION, "tint": DEVIATE_BURST_TINT},
	],
	&"DevImpact": [
		{"kind": SPRAY, "sequence": DEV_IMPACT_SEQUENCE,
			"frame_count": DEV_IMPACT_FRAME_COUNT, "size": DEV_IMPACT_SIZE,
			"duration": DEV_IMPACT_DURATION, "tint": DEV_IMPACT_TINT,
			"count": DEV_IMPACT_COUNT, "speed_min": DEV_IMPACT_SPEED_MIN,
			"speed_max": DEV_IMPACT_SPEED_MAX},
	],
}
const SHRAPNEL_SEQUENCE := "!@sm"
const SHRAPNEL_FRAME_COUNT := 11
const SHRAPNEL_SIZE := 0.16
const SHRAPNEL_ANIMATION_DURATION := 1.0
const SHRAPNEL_FADE_DURATION := 0.3
const SHRAPNEL_START_HEIGHT := 0.08
const SHRAPNEL_COUNT := 16
const SHRAPNEL_VERTICAL_SPEED_MIN := 0.8
const SHRAPNEL_VERTICAL_SPEED_MAX := 1.4
const SHRAPNEL_GRAVITY := 1.6
const SHRAPNEL_TINT := Color(1.8, 1.45, 0.72, 1.0)
const RING_SPEED := 1.4
const RING_VERTICAL_SPEED := 0.55
const RING_GRAVITY := 1.1
const LIGHT_COLOR := Color(1.0, 0.43, 0.12)
const LIGHT_RANGE := 3.5
const CLEANUP_MARGIN := 0.05

var _effect: Node3D
var _particle_index := 0
var _follow_particles: Array[Dictionary] = []
var _random := RandomNumberGenerator.new()


func _init() -> void:
	_random.randomize()


func configure(effect: Node3D) -> void:
	_effect = effect


## Whether this effect id has an authored emitter rig, which is also what
## decides that its invisible marker geometry must be hidden.
static func has_rig(effect_id: StringName) -> bool:
	return PIECES.has(effect_id)


## Spawns the effect's pieces around the owner's position. `authored_visual`
## supplies the animated marker each burst billboard follows.
func build(effect_id: StringName, authored_visual: Node3D) -> void:
	if _effect == null or authored_visual == null or not is_instance_valid(authored_visual):
		return
	var pieces: Array = PIECES.get(effect_id, [])
	for piece_value: Variant in pieces:
		var piece := piece_value as Dictionary
		match piece.get("kind"):
			BURST:
				_spawn_burst_piece(piece, authored_visual)
			SPRAY:
				_spawn_spray_piece(piece)

	if not _has_kind(pieces, SHRAPNEL) and not _has_kind(pieces, RING):
		return
	var shrapnel_textures := AuthoredFxBankScript.load_texture_sequence(
		SHRAPNEL_SEQUENCE, SHRAPNEL_FRAME_COUNT
	)
	if not shrapnel_textures.is_empty():
		if _has_kind(pieces, SHRAPNEL):
			_spawn_shrapnel(shrapnel_textures)
		if _has_kind(pieces, RING):
			_spawn_ring(shrapnel_textures)
	if _has_kind(pieces, LIGHT):
		_spawn_light()


static func _has_kind(pieces: Array, kind: StringName) -> bool:
	for piece_value: Variant in pieces:
		if (piece_value as Dictionary).get("kind") == kind:
			return true
	return false


func _spawn_burst_piece(piece: Dictionary, authored_visual: Node3D) -> void:
	var sequence := String(piece.get("sequence", BURST_SEQUENCE))
	var textures := AuthoredFxBankScript.load_texture_sequence(
		sequence, int(piece.get("frame_count", BURST_FRAME_COUNT))
	)
	var marker := AuthoredFxBankScript.find_original_node(
		authored_visual, String(piece.get("marker", BURST_MARKER))
	)
	if marker == null or textures.is_empty():
		return
	_spawn_follow_particle(
		sequence, textures, float(piece.get("size", BURST_SIZE)),
		float(piece.get("duration", BURST_DURATION)), marker,
		piece.get("tint", Color.WHITE) as Color,
		int(piece.get("smoke_first_frame", -1)), float(piece.get("smoke_opacity", 1.0))
	)


## An authored cloud that expands from the impact point instead of one
## billboard riding a marker. The bank carries no gravity, so the particles
## coast outward and simply finish their sprite sheet where they are.
func _spawn_spray_piece(piece: Dictionary) -> void:
	var sequence := String(piece.get("sequence", ""))
	var textures := AuthoredFxBankScript.load_texture_sequence(
		sequence, int(piece.get("frame_count", 0))
	)
	if textures.is_empty():
		return
	var size := float(piece.get("size", BURST_SIZE))
	var duration := float(piece.get("duration", BURST_DURATION))
	var tint := piece.get("tint", Color.WHITE) as Color
	var speed_min := float(piece.get("speed_min", 0.0))
	var speed_max := float(piece.get("speed_max", 0.0))
	var start := _effect.global_position
	for particle_number in int(piece.get("count", 1)):
		var angle := _random.randf_range(0.0, TAU)
		var direction := Vector3(sin(angle), 0.0, cos(angle))
		# Tilting each particle up by its own fraction turns the flat ring the
		# horizontal angle alone would draw into a dome.
		direction = (
			direction + Vector3.UP * _random.randf_range(0.0, DEV_IMPACT_RISE_FRACTION)
		).normalized()
		var velocity := direction * _random.randf_range(speed_min, speed_max)
		var particle := _spawn_world_particle(
			sequence, textures, size, duration, start, tint, true, -1, 1.0, velocity
		)
		if particle != null:
			particle.set_meta("combat_impact_velocity", velocity)


## How long the owner must stay alive for the rig to finish: the longest
## billboard piece, plus (only when authored) the slowest shrapnel/ring piece
## landing and fading before the node may be freed.
static func lifetime(effect_id: StringName) -> float:
	var pieces: Array = PIECES.get(effect_id, [])
	var longest := 0.0
	for piece_value: Variant in pieces:
		var piece := piece_value as Dictionary
		if piece.get("kind") in [BURST, SPRAY]:
			longest = maxf(longest, float(piece.get("duration", BURST_DURATION)))
	if _has_kind(pieces, SHRAPNEL) or _has_kind(pieces, RING):
		var maximum_flight_time := _ballistic_landing_time(
			SHRAPNEL_START_HEIGHT, SHRAPNEL_VERTICAL_SPEED_MAX, SHRAPNEL_GRAVITY
		)
		longest = maxf(
			longest,
			maxf(SHRAPNEL_ANIMATION_DURATION, maximum_flight_time)
				+ SHRAPNEL_FADE_DURATION + CLEANUP_MARGIN
		)
	return longest


## Copies each follower onto the marker it tracks, and reports whether any are
## left. The owner stops processing once none are.
func advance_followers() -> bool:
	for index in range(_follow_particles.size() - 1, -1, -1):
		var entry: Dictionary = _follow_particles[index]
		var particle_ref := entry.get("particle") as WeakRef
		var marker_ref := entry.get("marker") as WeakRef
		var particle := particle_ref.get_ref() as Node3D \
			if particle_ref != null else null
		var marker := marker_ref.get_ref() as Node3D \
			if marker_ref != null else null
		if particle == null or marker == null:
			_follow_particles.remove_at(index)
			continue
		particle.global_position = marker.global_position
	return not _follow_particles.is_empty()


## RocketDetonation repeatedly emits the same small shrapnel sprite while its
## helpers expand from the centre. Every particle shares one radial speed so
## the group remains a ring, while independent random angles keep its points
## from forming an artificial regular polygon.
func _spawn_ring(textures: Array[Texture2D]) -> void:
	var start := _effect.global_position + Vector3.UP * SHRAPNEL_START_HEIGHT
	for particle_number in SHRAPNEL_COUNT:
		var angle := _random.randf_range(0.0, TAU)
		var direction := Vector3(sin(angle), 0.0, cos(angle))
		var velocity := direction * RING_SPEED + Vector3.UP * RING_VERTICAL_SPEED
		var particle := _spawn_world_particle(
			SHRAPNEL_SEQUENCE, textures, SHRAPNEL_SIZE,
			SHRAPNEL_ANIMATION_DURATION, start, SHRAPNEL_TINT, false
		)
		if particle != null:
			particle.set_meta("combat_impact_ring", true)
			_throw(particle, start, velocity, RING_GRAVITY)


## The source effect is a loose radial spray, not four authored rays: every
## spark independently samples its direction and speed.
func _spawn_shrapnel(textures: Array[Texture2D]) -> void:
	var start := _effect.global_position + Vector3.UP * SHRAPNEL_START_HEIGHT
	for particle_number in SHRAPNEL_COUNT:
		var angle := _random.randf_range(0.0, TAU)
		var direction := Vector3(sin(angle), 0.0, cos(angle))
		var speed := _random.randf_range(0.55, 1.65)
		var velocity := direction * speed \
			+ Vector3.UP * _random.randf_range(
				SHRAPNEL_VERTICAL_SPEED_MIN, SHRAPNEL_VERTICAL_SPEED_MAX
			)
		var particle := _spawn_world_particle(
			SHRAPNEL_SEQUENCE, textures, SHRAPNEL_SIZE,
			SHRAPNEL_ANIMATION_DURATION, start, SHRAPNEL_TINT, false
		)
		if particle != null:
			_throw(particle, start, velocity, SHRAPNEL_GRAVITY)


## Puts one piece on a ballistic arc and fades it where it lands. The metadata
## is what tests/combat/run.gd reads to check the spray.
func _throw(particle: Node3D, start: Vector3, velocity: Vector3, gravity: float) -> void:
	var landing_time := _ballistic_landing_time(SHRAPNEL_START_HEIGHT, velocity.y, gravity)
	particle.set_meta("combat_impact_velocity", velocity)
	particle.set_meta("combat_impact_landing_time", landing_time)
	var motion := particle.create_tween().set_process_mode(Tween.TWEEN_PROCESS_PHYSICS)
	motion.tween_method(
		_update_particle_position.bind(particle, start, velocity, gravity),
		0.0, landing_time, landing_time
	)
	motion.finished.connect(_fade_landed.bind(particle))


static func _ballistic_landing_time(
		start_height: float,
		vertical_speed: float,
		gravity: float
	) -> float:
	if gravity <= 0.0:
		return SHRAPNEL_ANIMATION_DURATION
	return (vertical_speed + sqrt(
		vertical_speed * vertical_speed + 2.0 * gravity * maxf(start_height, 0.0)
	)) / gravity


func _fade_landed(particle: Node3D) -> void:
	if particle == null or not is_instance_valid(particle):
		return
	var visual := particle.get_node_or_null("Visual") as MeshInstance3D
	var material := (visual.mesh as QuadMesh).material as StandardMaterial3D \
		if visual != null else null
	if material == null:
		particle.queue_free()
		return
	var fade := particle.create_tween()
	fade.tween_method(
		_set_particle_opacity.bind(material),
		material.albedo_color.a, 0.0, SHRAPNEL_FADE_DURATION
	)
	fade.finished.connect(particle.queue_free)


func _spawn_light() -> void:
	var light := OmniLight3D.new()
	light.name = "ImpactLight"
	light.set_meta("combat_impact_light", true)
	light.light_color = LIGHT_COLOR
	light.light_energy = 5.0
	light.omni_range = LIGHT_RANGE
	light.shadow_enabled = false
	light.position = Vector3.UP * 0.12
	_effect.add_child(light)
	var illumination := light.create_tween()
	# Two-frame flash, then roughly ten source frames of local illumination.
	illumination.tween_property(light, "light_energy", 2.0, 0.1)
	illumination.tween_property(light, "light_energy", 0.8, 0.4)
	illumination.tween_property(light, "light_energy", 0.0, 0.1)
	illumination.finished.connect(light.queue_free)


func _spawn_follow_particle(
		sequence: String,
		textures: Array[Texture2D],
		size: float,
		duration: float,
		marker: Node3D,
		tint: Color = Color.WHITE,
		smoke_first_frame: int = -1,
		smoke_opacity: float = 1.0
	) -> Node3D:
	# Marker transforms carry source-model scale for their hidden cubes. Keep
	# the billboard in world space and copy only the animated marker position.
	var particle := _spawn_world_particle(
		sequence, textures, size, duration, marker.global_position,
		tint, true, smoke_first_frame, smoke_opacity
	)
	_follow_particles.append({
		"particle": weakref(particle),
		"marker": weakref(marker),
	})
	_effect.set_process(true)
	return particle


func _spawn_world_particle(
		sequence: String,
		textures: Array[Texture2D],
		size: float,
		duration: float,
		world_position: Vector3,
		tint: Color = Color.WHITE,
		free_after_animation: bool = true,
		smoke_first_frame: int = -1,
		smoke_opacity: float = 1.0,
		velocity: Vector3 = Vector3.ZERO
	) -> Node3D:
	var opacities := PackedFloat32Array()
	for frame_index in textures.size():
		opacities.append(
			smoke_opacity if smoke_first_frame >= 0 and frame_index >= smoke_first_frame
			else 1.0
		)
	var spawned := AuthoredFxBankScript.spawn_frame_animated_quad(
		_effect, textures, {
			"name": "ImpactParticle_%d" % _particle_index,
			"position": world_position,
			"size": size,
			"tint": tint,
			"frame_seconds": duration / float(maxi(textures.size(), 1)),
			"opacities": opacities,
			"free_after_animation": free_after_animation,
			"velocity": velocity,
			"metadata": {
				"combat_impact_particle": StringName(sequence),
			},
		}
	)
	_particle_index += 1
	return spawned.get("particle") as Node3D


func _update_particle_position(
		elapsed: float,
		particle: Node3D,
		start: Vector3,
		velocity: Vector3,
		gravity: float
	) -> void:
	AuthoredFxBankScript.integrate_motion(
		elapsed, particle, start, velocity, Vector3.DOWN * gravity
	)


func _set_particle_opacity(opacity: float, material: StandardMaterial3D) -> void:
	if material != null:
		var color := material.albedo_color
		color.a = opacity
		material.albedo_color = color
